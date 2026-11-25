// App state: loaded conversations, media folders, and the remembered session.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'parser.dart';
import 'settings.dart';

/// How well a conversation's photos/videos are covered by the opened folders.
class MediaStats {
  final int total; // media references found in the messages
  final int fromChat; // found in this conversation's own folders
  final int fromShared; // found in shared folders
  final int missing;
  final List<String> missingSample;
  const MediaStats(
    this.total,
    this.fromChat,
    this.fromShared,
    this.missing,
    this.missingSample,
  );
}

/// Collects the single digest produced by [Hash.startChunkedConversion].
class _DigestSink implements Sink<Digest> {
  Digest? _value;
  @override
  void add(Digest digest) => _value = digest;
  @override
  void close() {}
  Digest get value => _value!;
}

/// Streamed so a multi-gigabyte photo never has to fit in memory.
Future<Map<String, List<String>>> _hashMediaFiles(List<String> paths) async {
  final groups = <String, List<String>>{};
  for (final path in paths) {
    try {
      final f = File(path);
      final size = (await f.stat()).size;
      if (size == 0) continue;
      final digest = _DigestSink();
      final sink = sha256.startChunkedConversion(digest);
      await for (final chunk in f.openRead()) {
        sink.add(chunk);
      }
      sink.close();
      groups.putIfAbsent('$size|${digest.value}', () => <String>[]).add(path);
    } catch (_) {
      // An unreadable file is simply ignored by the duplicate report.
    }
  }
  groups.removeWhere((_, paths) => paths.length < 2);
  return groups;
}

/// One match from a conversation other than (or including) the open one.
class GlobalHit {
  final Chat chat;
  final Msg msg;
  const GlobalHit(this.chat, this.msg);
}

/// Maximum number of hits kept by global search. The screen shows a "+" when
/// [GlobalSearchResult.truncated] is true instead of pretending it counted all.
const int globalSearchLimit = 20000;

typedef GlobalSearchResult = ({List<GlobalHit> hits, bool truncated});

class Store extends ChangeNotifier {
  final AppSettings settings;
  Store(this.settings) {
    me = settings.me;
  }

  final Map<String, Chat> chats = {};

  /// JSON files already added in this session. Re-picking one must not append
  /// its messages a second time (the saved path list alone cannot prevent that).
  final Set<String> _loadedPaths = {};

  /// Folders used by every conversation. The export's file names are random IDs, so a folder
  /// is only a lookup table from "name written in the JSON" to the real file on disk.
  final List<MediaDir> sharedDirs = [];

  /// Bumped whenever any media folder is added or removed, so views know to refresh photos.
  int mediaVersion = 0;

  /// Bumped when loaded messages change, so expensive derived views can cache.
  int dataRevision = 0;

  /// Bumped when bookmarks change, so lightweight counters can refresh without
  /// rerunning analysis of every message.
  int bookmarkRevision = 0;

  /// Which JSON paths contributed each chat key. Lets us drop a remembered
  /// file once every conversation it contained has been removed from the app.
  final Map<String, Set<String>> _pathsForChat = {};

  /// Original message -> the messages that reply to it (for "Show replies").
  final Map<Msg, List<Msg>> _replyIndex = {};

  /// Stats depend only on the messages and the media folders, not on status or
  /// bookmarks. Avoid rescanning every message whenever a list rebuilds.
  final Map<String, MediaStats> _mediaStats = {};

  String me = '';
  String status = 'Open a JSON file to begin.';

  int _busy = 0;
  bool get busy => _busy > 0;

  List<Chat> get sortedChats =>
      chats.values.toList()..sort((a, b) => b.lastT.compareTo(a.lastT));

  /// Search every loaded conversation. Query is case-insensitive and covers
  /// text, both original and friendly sender names, links and media filenames.
  /// An empty query returns nothing: global search is not a message browser.
  /// Stops as soon as one result past [limit] is found so a broad query never
  /// builds an unbounded list on the UI thread.
  GlobalSearchResult searchAll(
    String query, {
    String? sender,
    bool mediaOnly = false,
    int limit = globalSearchLimit,
  }) {
    final q = query.trim().toLowerCase();
    final out = <GlobalHit>[];
    if (q.isEmpty) return (hits: out, truncated: false);

    var truncated = false;
    outer:
    for (final c in sortedChats) {
      for (final m in c.messages) {
        if (sender != null && m.sender != sender) continue;
        if (mediaOnly && m.media.isEmpty) continue;
        final hit =
            m.lower.contains(q) ||
            m.sender.toLowerCase().contains(q) ||
            settings.aliasFor(m.sender).toLowerCase().contains(q) ||
            (m.share.isNotEmpty && m.share.toLowerCase().contains(q)) ||
            m.media.any((x) => x.name.toLowerCase().contains(q));
        if (!hit) continue;
        if (out.length >= limit) {
          truncated = true;
          break outer;
        }
        out.add(GlobalHit(c, m));
      }
    }
    return (hits: out, truncated: truncated);
  }

  void setStatus(String s) {
    status = s;
    notifyListeners();
  }

  void setMe(String v) {
    me = v;
    settings.me = v;
    settings.save();
    notifyListeners();
  }

  // ---- media lookup: the conversation's own folders first, then the shared ones ----

  ({String path, bool fromChat})? _find(String uri, Chat? chat) {
    if (uri.isEmpty) return null;
    final base = uri.split(pathSep).last;
    final lower = base.toLowerCase();
    String? decoded;
    if (base.contains('%')) {
      try {
        decoded = Uri.decodeComponent(base).toLowerCase();
      } catch (_) {}
    }
    if (chat != null) {
      for (final d in chat.dirs) {
        final p = d.files[lower] ?? (decoded == null ? null : d.files[decoded]);
        if (p != null) return (path: p, fromChat: true);
      }
    }
    for (final d in sharedDirs) {
      final p = d.files[lower] ?? (decoded == null ? null : d.files[decoded]);
      if (p != null) return (path: p, fromChat: false);
    }
    return null;
  }

  String? findMedia(String uri, [Chat? chat]) => _find(uri, chat)?.path;

  bool hasMedia([Chat? chat]) =>
      sharedDirs.isNotEmpty || (chat != null && chat.dirs.isNotEmpty);

  /// Groups identical media files by size + SHA-256. Hashing and streaming
  /// happen in an isolate so the chat stays responsive.
  Future<Map<String, List<String>>> duplicateMedia() async {
    final paths = <String>{};
    for (final c in chats.values) {
      for (final d in [...c.dirs, ...sharedDirs]) {
        paths.addAll(d.files.values);
      }
    }
    if (paths.isEmpty) return <String, List<String>>{};
    return compute(_hashMediaFiles, paths.toList());
  }

  MediaStats statsFor(Chat chat) {
    final key = '${chat.key}|${chat.messages.length}|$mediaVersion';
    final cached = _mediaStats[key];
    if (cached != null) return cached;

    var total = 0, fromChat = 0, fromShared = 0, missing = 0;
    final sample = <String>[];
    for (final m in chat.messages) {
      for (final x in m.media) {
        if (x.uri.isEmpty) continue;
        total++;
        final r = _find(x.uri, chat);
        if (r == null) {
          missing++;
          if (sample.length < 30) sample.add(x.name);
        } else if (r.fromChat) {
          fromChat++;
        } else {
          fromShared++;
        }
      }
    }
    final stats = MediaStats(total, fromChat, fromShared, missing, sample);
    _mediaStats[key] = stats;
    return stats;
  }

  /// Full list of missing media names for export. [MediaStats.missingSample]
  /// is intentionally capped for dialogs; CSV exports must not be truncated.
  List<String> missingMediaNames(Chat chat) {
    final out = <String>[];
    for (final m in chat.messages) {
      for (final x in m.media) {
        if (x.uri.isEmpty) continue;
        if (_find(x.uri, chat) == null) out.add(x.name);
      }
    }
    return out;
  }

  // ---- replies ----

  /// Link every reply to the message it answers (by message ID, or by time + sender).
  /// Returns how many messages in the conversation are replies.
  int resolveReplies(Chat c) {
    final withReply = <Msg>[];
    for (final m in c.messages) {
      if (m.reply != null) withReply.add(m);
    }
    if (withReply.isEmpty) return 0;
    final byId = <String, Msg>{};
    final byKey = <String, Msg>{};
    for (final m in c.messages) {
      if (m.id.isNotEmpty) byId[m.id] = m;
      if (m.t != null) byKey['${m.t}|${m.sender}'] = m;
    }
    for (final m in withReply) {
      final r = m.reply!;
      Msg? target;
      if (r.id.isNotEmpty) target = byId[r.id];
      if (target == null && r.t != null && r.sender.isNotEmpty) {
        target = byKey['${r.t}|${r.sender}'];
      }
      m.replyTarget = target;
      if (target != null) {
        _replyIndex.putIfAbsent(target, () => <Msg>[]).add(m);
      }
    }
    return withReply.length;
  }

  /// Rebuild the reply index after any change to the loaded conversations.
  /// Removal is rare, so a full rebuild is cheaper than a stale index that
  /// keeps removed messages (and their raw JSON) alive.
  int rebuildReplyIndex() {
    _replyIndex.clear();
    var count = 0;
    for (final c in chats.values) {
      count += resolveReplies(c);
    }
    return count;
  }

  List<Msg> repliesTo(Msg m) =>
      List.unmodifiable(_replyIndex[m] ?? const <Msg>[]);

  /// Most callers only need the count, so avoid allocating an unmodifiable list.
  int replyCount(Msg m) => _replyIndex[m]?.length ?? 0;

  // ---- bookmarks and notes ----

  static String messageKey(Msg m) =>
      m.id.isNotEmpty ? m.id : '${m.t}|${m.sender}';

  bool isBookmarked(Chat c, Msg m) =>
      settings.bookmarks[c.key]?.contains(messageKey(m)) ?? false;

  void toggleBookmark(Chat c, Msg m) {
    final list = settings.bookmarks.putIfAbsent(c.key, () => <String>[]);
    final k = messageKey(m);
    if (list.contains(k)) {
      list.remove(k);
    } else {
      list.add(k);
    }
    if (list.isEmpty) settings.bookmarks.remove(c.key);
    bookmarkRevision++;
    settings.save();
    notifyListeners();
  }

  String noteFor(Chat c, Msg m) =>
      settings.notes['${c.key}|${messageKey(m)}'] ?? '';

  void setNote(Chat c, Msg m, String note) {
    final k = '${c.key}|${messageKey(m)}';
    final v = note.trim();
    if (v.isEmpty) {
      settings.notes.remove(k);
    } else {
      settings.notes[k] = v;
    }
    settings.save();
    notifyListeners();
  }

  /// Every bookmarked message, grouped by conversation through [GlobalHit.chat].
  List<GlobalHit> bookmarked() {
    final out = <GlobalHit>[];
    for (final c in sortedChats) {
      for (final m in c.messages) {
        if (isBookmarked(c, m)) out.add(GlobalHit(c, m));
      }
    }
    return out;
  }

  // ---- loading ----

  static String dedupeKey(Msg m) => m.id.isNotEmpty
      ? 'id:${m.id}'
      : 'msg:${m.t}|${m.sender}|${m.text}|${m.media.map((x) => x.uri).join(',')}';

  Future<void> addJsonFiles(List<String> paths, {bool remember = true}) async {
    var added = 0;
    var duplicates = 0;
    var skippedRemoved = 0;
    final problems = <String>[];
    final seen = <String>{};
    if (settings.dedupeImports) {
      for (final c in chats.values) {
        for (final m in c.messages) {
          seen.add('${c.key}|${dedupeKey(m)}');
        }
      }
    }
    _busy++;
    notifyListeners();
    try {
      for (final path in paths) {
        final name = path.split(pathSep).last;
        if (_loadedPaths.contains(path)) continue;
        status = 'Reading $name…';
        notifyListeners();
        try {
          // Parsing runs in a background isolate so the window never freezes.
          // The first launch parses the export; later launches read the cache.
          final threads = await parseInBackground(
            path,
            cacheDir: settings.useParseCache ? settings.cacheDir : null,
            keepRaw: settings.keepRaw,
            useCache: settings.useParseCache,
          );
          if (threads.isEmpty) {
            problems.add('$name: no messages found');
            continue;
          }
          final activeKeys = <String>{};
          for (final t in threads) {
            if (settings.removedChats.contains(t.key)) {
              skippedRemoved++;
              continue;
            }
            activeKeys.add(t.key);
            _pathsForChat.putIfAbsent(t.key, () => <String>{}).add(path);
            final c = chats.putIfAbsent(t.key, () => Chat(t.key, t.title));
            c.participants.addAll(t.participants);
            for (final m in t.messages) {
              c.participants.add(m.sender);
              final k = '${c.key}|${dedupeKey(m)}';
              if (settings.dedupeImports && !seen.add(k)) {
                duplicates++;
                continue;
              }
              c.messages.add(m);
              added++;
            }
          }
          // A file whose only conversations were removed must not be reopened
          // on every startup, nor block re-adding it later in this session.
          if (activeKeys.isNotEmpty) {
            _loadedPaths.add(path);
            if (remember && !settings.jsonPaths.contains(path)) {
              settings.jsonPaths.add(path);
            }
          } else if (remember) {
            settings.jsonPaths.remove(path);
          }
        } catch (e) {
          problems.add('$name: $e');
        }
      }
    } finally {
      _busy--;
    }
    for (final c in chats.values) {
      c.messages.sort((a, b) => (a.t ?? 0).compareTo(b.t ?? 0));
    }
    _mediaStats.clear();
    final replies = rebuildReplyIndex();
    dataRevision++;
    if (remember) settings.save();
    status =
        'Loaded $added messages.'
        '${duplicates > 0 ? ' Skipped $duplicates duplicates.' : ''}'
        '${skippedRemoved > 0 ? ' Skipped $skippedRemoved removed conversation(s).' : ''}'
        '${replies > 0 ? ' $replies of them are replies.' : ''}'
        '${problems.isEmpty ? '' : ' Problems: ${problems.join(' | ')}'}';
    notifyListeners();
  }

  /// Open a media folder. With [chat] it belongs to that conversation only;
  /// without it, the folder is shared by every conversation.
  Future<void> addMediaDir(
    String dir, {
    Chat? chat,
    bool remember = true,
  }) async {
    status = 'Scanning $dir …';
    _busy++;
    notifyListeners();
    Map<String, String> files;
    try {
      files = await scanInBackground(dir);
    } catch (e) {
      status = 'Could not scan $dir: $e';
      _busy--;
      notifyListeners();
      return;
    }
    _busy--;
    final list = chat?.dirs ?? sharedDirs;
    list.removeWhere(
      (d) => d.path == dir,
    ); // opening the same folder again just rescans it
    list.add(MediaDir(dir, files));
    mediaVersion++;
    if (remember) {
      final saved = chat == null
          ? settings.sharedDirs
          : settings.chatDirs.putIfAbsent(chat.key, () => <String>[]);
      if (!saved.contains(dir)) saved.add(dir);
      settings.save();
    }
    status =
        'Indexed ${files.length} files from $dir '
        '${chat == null ? '(shared by all conversations)' : '(for "${chat.title}")'}.';
    notifyListeners();
  }

  void removeMediaDir(MediaDir d, {Chat? chat}) {
    (chat?.dirs ?? sharedDirs).remove(d);
    if (chat == null) {
      settings.sharedDirs.remove(d.path);
    } else {
      settings.chatDirs[chat.key]?.remove(d.path);
    }
    settings.save();
    mediaVersion++;
    status = 'Removed folder ${d.path}.';
    notifyListeners();
  }

  /// Hide a conversation from the list without deleting anything.
  void toggleArchive(Chat c) {
    final archived = settings.archivedChats.contains(c.key);
    if (archived) {
      settings.archivedChats.remove(c.key);
    } else {
      settings.archivedChats.add(c.key);
    }
    settings.save();
    status = archived
        ? 'Unarchived "${c.title}".'
        : 'Archived "${c.title}". Use Show archived to see it again.';
    notifyListeners();
  }

  /// Remove a conversation from this app. The JSON file is left untouched.
  void removeChat(Chat c) {
    settings.removedChats.add(c.key);
    settings.archivedChats.remove(c.key);
    chats.remove(c.key);
    _mediaStats.clear();
    rebuildReplyIndex();
    dataRevision++;
    final paths = _pathsForChat.remove(c.key) ?? const <String>{};
    for (final path in paths) {
      if (!_pathsForChat.values.any((owned) => owned.contains(path))) {
        settings.jsonPaths.remove(path);
        _loadedPaths.remove(path);
      }
    }
    settings.chatPos.remove(c.key);
    if (settings.bookmarks.remove(c.key) != null) bookmarkRevision++;
    settings.chatDirs.remove(c.key);
    final prefix = '${c.key}|';
    settings.notes.removeWhere((key, _) => key.startsWith(prefix));
    if (settings.lastChat == c.key) settings.lastChat = '';
    settings.save();
    status =
        'Removed "${c.title}" from the app. The JSON file was not deleted.';
    notifyListeners();
  }

  // ---- remembered session ----

  /// Reopen the JSON files and media folders from the last run.
  Future<void> restoreSession() async {
    final gone = <String>[];
    final jsons = <String>[];
    for (final p in settings.jsonPaths) {
      (File(p).existsSync() ? jsons : gone).add(p);
    }
    if (jsons.isNotEmpty) await addJsonFiles(jsons, remember: false);
    for (final d in settings.sharedDirs) {
      if (Directory(d).existsSync()) {
        await addMediaDir(d, remember: false);
      } else {
        gone.add(d);
      }
    }
    for (final e in settings.chatDirs.entries) {
      final c = chats[e.key];
      if (c == null) continue;
      for (final d in e.value) {
        if (Directory(d).existsSync()) {
          await addMediaDir(d, chat: c, remember: false);
        } else {
          gone.add(d);
        }
      }
    }
    if (jsons.isNotEmpty || gone.isNotEmpty) {
      status =
          'Reopened ${jsons.length} file(s) from the last session.'
          '${gone.isEmpty ? '' : ' Not found any more: ${gone.map((p) => p.split(pathSep).last).join(', ')}'}';
    }
    notifyListeners();
  }

  /// Forget the saved file and folder list (settings like theme are kept).
  void forgetSession() {
    settings.jsonPaths = [];
    settings.sharedDirs = [];
    settings.chatDirs = {};
    settings.chatPos = {};
    settings.lastChat = '';
    settings.save();
  }

  void clear() {
    chats.clear();
    _replyIndex.clear();
    _mediaStats.clear();
    _pathsForChat.clear();
    _loadedPaths.clear();
    sharedDirs.clear();
    mediaVersion++;
    dataRevision++;
    bookmarkRevision++;
    forgetSession();
    status = 'Cleared.';
    notifyListeners();
  }
}
