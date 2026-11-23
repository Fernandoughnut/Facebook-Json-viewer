// App state: loaded conversations and the media folders.

import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'parser.dart';

/// How well a conversation's photos/videos are covered by the opened folders.
class MediaStats {
  final int total; // media references found in the messages
  final int fromChat; // found in this conversation's own folders
  final int fromShared; // found in shared folders
  final int missing;
  final List<String> missingSample;
  const MediaStats(this.total, this.fromChat, this.fromShared, this.missing, this.missingSample);
}

class Store extends ChangeNotifier {
  final Map<String, Chat> chats = {};

  /// Folders used by every conversation. The export's file names are random IDs, so a folder
  /// is only a lookup table from "name written in the JSON" to the real file on disk.
  final List<MediaDir> sharedDirs = [];

  /// Bumped whenever any media folder is added or removed, so views know to refresh photos.
  int mediaVersion = 0;

  String me = '';
  String status = 'Open a JSON file to begin.';

  List<Chat> get sortedChats => chats.values.toList()..sort((a, b) => b.lastT.compareTo(a.lastT));

  void setStatus(String s) {
    status = s;
    notifyListeners();
  }

  void setMe(String v) {
    me = v;
    notifyListeners();
  }

  // ---- media lookup: the conversation's own folders first, then the shared ones ----

  ({String path, bool fromChat})? _find(String uri, Chat? chat) {
    if (uri.isEmpty) return null;
    final base = uri.split(RegExp(r'[\\/]')).last;
    final keys = <String>[base.toLowerCase()];
    try {
      final decoded = Uri.decodeComponent(base).toLowerCase();
      if (decoded != keys.first) keys.add(decoded);
    } catch (_) {}
    if (chat != null) {
      for (final d in chat.dirs) {
        for (final k in keys) {
          final p = d.files[k];
          if (p != null) return (path: p, fromChat: true);
        }
      }
    }
    for (final d in sharedDirs) {
      for (final k in keys) {
        final p = d.files[k];
        if (p != null) return (path: p, fromChat: false);
      }
    }
    return null;
  }

  String? findMedia(String uri, [Chat? chat]) => _find(uri, chat)?.path;

  bool hasMedia([Chat? chat]) => sharedDirs.isNotEmpty || (chat != null && chat.dirs.isNotEmpty);

  MediaStats statsFor(Chat chat) {
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
    return MediaStats(total, fromChat, fromShared, missing, sample);
  }

  // ---- loading ----

  Future<void> addJsonFiles(List<String> paths) async {
    var added = 0;
    final problems = <String>[];
    for (final path in paths) {
      final name = path.split(RegExp(r'[\\/]')).last;
      status = 'Reading $name…';
      notifyListeners();
      try {
        // Parsing runs in a background isolate so the window never freezes.
        final threads = await Isolate.run(() => parseFile(path));
        if (threads.isEmpty) {
          problems.add('$name: no messages found');
          continue;
        }
        for (final t in threads) {
          final c = chats.putIfAbsent(t.key, () => Chat(t.key, t.title));
          c.participants.addAll(t.participants);
          for (final m in t.messages) {
            c.participants.add(m.sender);
            c.messages.add(m);
          }
          added += t.messages.length;
        }
      } catch (e) {
        problems.add('$name: $e');
      }
    }
    for (final c in chats.values) {
      c.messages.sort((a, b) => (a.t ?? 0).compareTo(b.t ?? 0));
    }
    status = 'Loaded $added messages.${problems.isEmpty ? '' : ' Problems: ${problems.join(' | ')}'}';
    notifyListeners();
  }

  /// Open a media folder. With [chat] it belongs to that conversation only;
  /// without it, the folder is shared by every conversation.
  Future<void> addMediaDir(String dir, {Chat? chat}) async {
    status = 'Scanning $dir …';
    notifyListeners();
    final files = await Isolate.run(() => scanDir(dir));
    final list = chat?.dirs ?? sharedDirs;
    list.removeWhere((d) => d.path == dir); // opening the same folder again just rescans it
    list.add(MediaDir(dir, files));
    mediaVersion++;
    status = 'Indexed ${files.length} files from $dir '
        '${chat == null ? '(shared by all conversations)' : '(for "${chat.title}")'}.';
    notifyListeners();
  }

  void removeMediaDir(MediaDir d, {Chat? chat}) {
    (chat?.dirs ?? sharedDirs).remove(d);
    mediaVersion++;
    status = 'Removed folder ${d.path}.';
    notifyListeners();
  }

  void clear() {
    chats.clear();
    sharedDirs.clear();
    mediaVersion++;
    status = 'Cleared.';
    notifyListeners();
  }
}
