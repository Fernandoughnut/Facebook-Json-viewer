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

/// Maximum hits kept by global search; results report truncation past this.
const int globalSearchLimit = 20000;

typedef GlobalSearchResult = ({List<GlobalHit> hits, bool truncated});

class Store extends ChangeNotifier {
  static const int _maxMediaStatsEntries = 128;

  final AppSettings settings;
  Store(this.settings) {
    me = settings.me;
  }

  final Map<String, Chat> chats = {};

  /// JSON files already added this session, so re-picking one cannot append duplicates.
  final Set<String> _loadedPaths = {};

  /// Shared media folders map export filenames to files on disk.
  final List<MediaDir> sharedDirs = [];

  /// Bumped whenever any media folder is added or removed, so views know to refresh photos.
  int mediaVersion = 0;

  /// Bumped when loaded messages change, so expensive derived views can cache.
  int dataRevision = 0;

  /// Bumped when bookmarks change, for lightweight counter refreshes.
  int bookmarkRevision = 0;

  /// JSON paths that contributed each chat key, so removed files can be forgotten.
  final Map<String, Set<String>> _pathsForChat = {};

  /// Exact message objects contributed by each JSON path. An explicit re-add
  /// can replace stale source data without discarding overlapping copies from
  /// other files. Identity matters: two files may hold identical messages.
  final Map<String, Map<String, Set<Msg>>> _sourceKeys = {};

  /// Original message -> the messages that reply to it (for "Show replies").
  final Map<Msg, List<Msg>> _replyIndex = {};

  /// Stats depend only on messages and media folders, not bookmarks or status.
  final Map<String, MediaStats> _mediaStats = {};

  String me = '';
  String status = 'Open a JSON file to begin.';

  int _busy = 0;
  bool get busy => _busy > 0;

  List<Chat>? _sortedChatsCache;
  int _sortedChatsRevision = -1;
  int _sortedChatsCount = -1;

  /// Read-only, cached until messages or chats change. Sidebar rebuilds and
  /// global search both ask for this on every keystroke.
  List<Chat> get sortedChats {
    if (_sortedChatsCache != null &&
        _sortedChatsRevision == dataRevision &&
        _sortedChatsCount == chats.length) {
      return _sortedChatsCache!;
    }
    final list = chats.values.toList()
      ..sort((a, b) => b.lastT.compareTo(a.lastT));
    _sortedChatsCache = list;
    _sortedChatsRevision = dataRevision;
    _sortedChatsCount = chats.length;
    return list;
  }

  /// Case-insensitive global search over text, sender names, links and filenames.
  /// Empty query returns nothing; it stops just past [limit] to avoid unbounded work.
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
            m.lowerSender.contains(q) ||
            settings.lowerAliasFor(m.sender).contains(q) ||
            (m.lowerShare.isNotEmpty && m.lowerShare.contains(q)) ||
            m.lowerMediaNames.any((name) => name.contains(q));
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

  static String _uriKey(String value) {
    final parts = <String>[];
    for (final part in value.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.' || part == '..') continue;
      parts.add(part);
    }
    return parts.join('/').toLowerCase();
  }

  static bool _isMediaFile(String path) {
    try {
      return File(path).statSync().type == FileSystemEntityType.file;
    } catch (_) {
      return false;
    }
  }

  ({String path, bool fromChat})? _find(String uri, Chat? chat) {
    if (uri.isEmpty) return null;
    final key = _uriKey(uri);
    String? decodedKey;
    try {
      decodedKey = _uriKey(Uri.decodeComponent(uri));
    } catch (_) {}
    final base = key.split('/').last;
    final decodedBase = decodedKey?.split('/').last;
    // Relative paths first, so same-named files in different folders stay distinct.
    final candidates = <String>{
      if (key.isNotEmpty) key,
      if (decodedKey != null && decodedKey.isNotEmpty) decodedKey,
      if (base.isNotEmpty) base,
      if (decodedBase != null && decodedBase.isNotEmpty) decodedBase,
    }.toList();
    final checked = <String>{};

    String? lookup(MediaDir d) {
      String? fromCandidate(String candidate) {
        final direct = d.paths[candidate];
        if (direct != null && checked.add(direct) && _isMediaFile(direct)) {
          return direct;
        }
        // originalSorted packs keep relative folders under `media/`.
        // A folder tail index turns lookups into map reads.
        if (candidate.contains('/')) {
          for (final path in d.suffixes[candidate] ?? const <String>[]) {
            if (checked.add(path) && _isMediaFile(path)) return path;
          }
        }
        // Old flat media folders only have a basename index.
        final name = candidate.split('/').last;
        final byName = d.files[name] ?? d.files[candidate];
        if (byName != null && checked.add(byName) && _isMediaFile(byName)) {
          return byName;
        }
        return null;
      }

      for (final candidate in candidates) {
        final path = fromCandidate(candidate);
        if (path != null) return path;
      }
      return null;
    }

    if (chat != null) {
      for (final d in chat.dirs) {
        final path = lookup(d);
        if (path != null) return (path: path, fromChat: true);
      }
    }
    for (final d in sharedDirs) {
      final path = lookup(d);
      if (path != null) return (path: path, fromChat: false);
    }
    return null;
  }

  String? findMedia(String uri, [Chat? chat]) => _find(uri, chat)?.path;

  bool hasMedia([Chat? chat]) =>
      sharedDirs.isNotEmpty || (chat != null && chat.dirs.isNotEmpty);

  /// Groups identical media by size + SHA-256 in an isolate.
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
    final key =
        '${chat.key}|${chat.messages.length}|$mediaVersion|$dataRevision';
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
    // Keep only a bounded window of folder/message versions.
    if (_mediaStats.length > _maxMediaStatsEntries) {
      _mediaStats.remove(_mediaStats.keys.first);
    }
    return stats;
  }

  /// Full missing-media list for CSV; [MediaStats.missingSample] is capped for dialogs.
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

  /// Link replies by ID or time+sender; returns the reply count.
  int resolveReplies(Chat c) {
    final withReply = <Msg>[];
    for (final m in c.messages) {
      if (m.reply != null) withReply.add(m);
    }
    for (final m in c.messages) {
      _replyIndex.remove(m);
      m.replyTarget = null;
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

  /// Rebuild after changes; a stale index would retain removed messages and raw JSON.
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

  Map<String, Set<String>>? _bookmarkSets;

  Map<String, Set<String>> get _bookmarkIndex {
    final cached = _bookmarkSets;
    if (cached != null) return cached;
    return _bookmarkSets = {
      for (final entry in settings.bookmarks.entries)
        entry.key: entry.value.toSet(),
    };
  }

  bool isBookmarked(Chat c, Msg m) =>
      _bookmarkIndex[c.key]?.contains(messageKey(m)) ?? false;

  void toggleBookmark(Chat c, Msg m) {
    final list = settings.bookmarks.putIfAbsent(c.key, () => <String>[]);
    final keys = _bookmarkIndex.putIfAbsent(c.key, () => <String>{});
    final k = messageKey(m);
    final removing = !keys.add(k);
    if (removing) {
      keys.remove(k);
      list.remove(k);
    } else {
      list.add(k);
    }
    if (list.isEmpty) {
      settings.bookmarks.remove(c.key);
      _bookmarkIndex.remove(c.key);
    }
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

  /// Exact identity: a 29-bit Object.hash would silently drop messages when
  /// distinct keys collide in a large export.
  static String _dedupeKey(String chatKey, Msg m) =>
      '$chatKey\u0000${dedupeKey(m)}';

  /// Forget only the messages that came from [path]. Other overlapping exports
  /// keep their copies, so an edited file can replace its own stale messages.
  bool _forgetPathContributions(String path) {
    final byChat = _sourceKeys.remove(path);
    if (byChat == null || byChat.isEmpty) return false;
    var changed = false;
    for (final entry in byChat.entries) {
      final c = chats[entry.key];
      if (c != null) {
        final before = c.messages.length;
        c.messages.removeWhere(entry.value.contains);
        changed |= c.messages.length != before;
      }
      final owners = _pathsForChat[entry.key];
      owners?.remove(path);
      if (owners != null && owners.isEmpty) _pathsForChat.remove(entry.key);
    }
    return changed;
  }

  /// Android cache picks are wiped between runs, so remembered files get durable copies.
  Future<String> _persistJsonPath(String path) async {
    if (!Platform.isAndroid) return path;
    // SAF imports already live under importDir; do not re-copy them on restore.
    if (path.startsWith('${settings.importDir}${Platform.pathSeparator}')) {
      return path;
    }
    final src = File(path);
    if (!await src.exists()) return path;
    final dir = Directory(settings.importDir);
    await dir.create(recursive: true);
    final raw = path.split(Platform.pathSeparator).last;
    final clean = raw.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
    final name = clean.isEmpty ? 'import.json' : clean;
    var target = File('${dir.path}${Platform.pathSeparator}$name');
    if (await target.exists()) {
      // Reuse unchanged files on restore, but compare more than size/mtime.
      var unchanged = false;
      try {
        unchanged =
            quickFileFingerprint(src.path) == quickFileFingerprint(target.path);
      } catch (_) {
        // A missing or unreadable copy is replaced below.
      }
      if (unchanged) return target.path;
      target = File(
        '${dir.path}${Platform.pathSeparator}'
        '${DateTime.now().microsecondsSinceEpoch}-$name',
      );
    }
    await src.copy(target.path);
    return target.path;
  }

  Future<void> addJsonFiles(
    List<String> paths, {
    bool remember = true,
    bool reviveRemoved = false,

    /// False for durable Android SAF JSON files, preserving nested names.
    /// They are not copied again into flat `imports/`.
    bool persist = true,
  }) async {
    var added = 0;
    var duplicates = 0;
    var skippedRemoved = 0;
    var prunedRememberedPath = false;
    var replaced = false;
    final problems = <String>[];
    final seen = <String>{};
    final touched = <String>{};
    if (settings.dedupeImports) {
      for (final c in chats.values) {
        for (final m in c.messages) {
          seen.add(_dedupeKey(c.key, m));
        }
      }
    }
    _busy++;
    notifyListeners();
    try {
      for (final picked in paths) {
        final path = persist ? await _persistJsonPath(picked) : picked;
        final name = path.split(pathSep).last;
        // Explicit re-adds bypass the session guard; per-thread checks still apply.
        if (!reviveRemoved && _loadedPaths.contains(path)) continue;
        final isReadd = reviveRemoved && _loadedPaths.contains(path);
        final replacedKeys = isReadd
            ? (_sourceKeys[path]?.keys.toList() ?? <String>[])
            : <String>[];
        status = 'Reading $name…';
        notifyListeners();
        try {
          // Parse in an isolate; first launch parses, later launches read the cache.
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
          if (isReadd && _forgetPathContributions(path)) {
            replaced = true;
            touched.addAll(replacedKeys);
            // The old copies are gone, so exact dedupe must be rebuilt too.
            seen.clear();
            for (final c in chats.values) {
              for (final m in c.messages) {
                seen.add(_dedupeKey(c.key, m));
              }
            }
          }
          final activeKeys = <String>{};
          final pathKeys = _sourceKeys.putIfAbsent(
            path,
            () => <String, Set<Msg>>{},
          );
          for (final t in threads) {
            final wasRemoved = settings.removedChats.contains(t.key);
            if (wasRemoved && !reviveRemoved) {
              skippedRemoved++;
              continue;
            }
            if (wasRemoved) settings.removedChats.remove(t.key);
            // A loaded thread stays remembered but is not merged twice.
            activeKeys.add(t.key);
            if (!wasRemoved &&
                !isReadd &&
                (_pathsForChat[t.key]?.contains(path) ?? false)) {
              continue;
            }
            final owners = _pathsForChat.putIfAbsent(t.key, () => <String>{});
            if (!owners.contains(path)) owners.add(path);
            final c = chats.putIfAbsent(t.key, () => Chat(t.key, t.title));
            c.participants.addAll(t.participants);
            final msgsForChat = pathKeys.putIfAbsent(t.key, () => <Msg>{});
            for (final m in t.messages) {
              c.participants.add(m.sender);
              if (settings.dedupeImports && !seen.add(_dedupeKey(c.key, m))) {
                duplicates++;
                continue;
              }
              c.messages.add(m);
              msgsForChat.add(m);
              touched.add(t.key);
              added++;
            }
          }
          // A file with only removed chats must not reopen at startup or block re-add.
          if (activeKeys.isNotEmpty) {
            _loadedPaths.add(path);
            if (remember && !settings.jsonPaths.contains(path)) {
              settings.jsonPaths.add(path);
            }
          } else {
            // Restore also skips files whose only chats were removed.
            prunedRememberedPath |= settings.jsonPaths.remove(path);
            _loadedPaths.remove(path);
            _sourceKeys.remove(path);
          }
        } catch (e) {
          problems.add('$name: $e');
        }
      }
    } finally {
      _busy--;
    }
    // Only loaded or replaced messages can change order; duplicated re-picks
    // must not invalidate caches.
    var replies = 0;
    if (added > 0 || replaced) {
      for (final key in touched) {
        chats[key]?.messages.sort((a, b) => (a.t ?? 0).compareTo(b.t ?? 0));
      }
      _mediaStats.clear();
      replies = rebuildReplyIndex();
      dataRevision++;
    }
    if (remember || prunedRememberedPath) settings.save();
    status =
        'Loaded $added messages.'
        '${duplicates > 0 ? ' Skipped $duplicates duplicates.' : ''}'
        '${skippedRemoved > 0 ? ' Skipped $skippedRemoved removed conversation(s).' : ''}'
        '${replies > 0 ? ' Linked $replies reply references.' : ''}'
        '${problems.isEmpty ? '' : ' Problems: ${problems.join(' | ')}'}';
    notifyListeners();
  }

  /// Open a media folder, shared unless [chat] is given.
  static bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static bool _sameFileMap(MediaDir a, MediaDir b) =>
      _sameMap(a.files, b.files) && _sameMap(a.paths, b.paths);

  Future<void> addMediaDir(
    String dir, {
    Chat? chat,
    bool remember = true,
  }) async {
    status = 'Scanning $dir …';
    _busy++;
    notifyListeners();
    late final MediaDirIndex index;
    try {
      index = await scanInBackground(dir);
    } catch (e) {
      status = 'Could not scan $dir: $e';
      _busy--;
      notifyListeners();
      return;
    }
    _busy--;
    final list = chat?.dirs ?? sharedDirs;
    final previous = list.where((d) => d.path == dir);
    var unchanged = false;
    for (final d in previous) {
      // Re-picking an unchanged folder avoids a full O(messages) rescan.
      unchanged = _sameFileMap(d, MediaDir(dir, index.files, index.paths));
      break;
    }
    if (!unchanged) {
      list.removeWhere((d) => d.path == dir);
      list.add(MediaDir(dir, index.files, index.paths));
      mediaVersion++;
    }
    if (remember) {
      final saved = chat == null
          ? settings.sharedDirs
          : settings.chatDirs.putIfAbsent(chat.key, () => <String>[]);
      if (!saved.contains(dir)) saved.add(dir);
      settings.save();
    }
    status =
        'Indexed ${index.files.length} files from $dir '
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
    if (settings.bookmarks.remove(c.key) != null) {
      _bookmarkSets?.remove(c.key);
      bookmarkRevision++;
    }
    settings.chatDirs.remove(c.key);
    for (final byChat in _sourceKeys.values) {
      byChat.remove(c.key);
    }
    _sourceKeys.removeWhere((_, byChat) => byChat.isEmpty);
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
    _bookmarkSets = null;
    _sourceKeys.clear();
    settings.save();
  }

  void clear() {
    chats.clear();
    _replyIndex.clear();
    _mediaStats.clear();
    _bookmarkSets = null;
    _pathsForChat.clear();
    _loadedPaths.clear();
    _sourceKeys.clear();
    sharedDirs.clear();
    mediaVersion++;
    dataRevision++;
    bookmarkRevision++;
    forgetSession();
    status = 'Cleared.';
    notifyListeners();
  }
}
