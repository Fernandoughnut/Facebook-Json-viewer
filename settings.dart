// User settings and the remembered session, stored in one small JSON file.
//
// Linux location: $XDG_CONFIG_HOME/fb_viewer/state.json (usually ~/.config/fb_viewer/state.json).
// On Android this will move to the app's private folder in the Android step; until then
// saving there fails silently and the app simply starts fresh each time.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class AppSettings extends ChangeNotifier {
  // ---- appearance and behaviour ----
  ThemeMode themeMode = ThemeMode.system;
  int accent = 0xFF0B7CFF;
  double textScale = 1.0;
  bool use24h = true;
  bool showTimes = true;
  double chatImageWidth = 260;
  double galleryTileSize = 140;
  bool reopenLast = true;

  // ---- last session ----
  List<String> jsonPaths = [];
  List<String> sharedDirs = [];
  Map<String, List<String>> chatDirs = {}; // conversation key -> folders
  String me = '';
  String lastChat = '';

  Timer? _timer;

  String get filePath {
    final home = Platform.environment['HOME'] ?? '.';
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return '$base/fb_viewer/state.json';
  }

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'accent': accent,
        'textScale': textScale,
        'use24h': use24h,
        'showTimes': showTimes,
        'chatImageWidth': chatImageWidth,
        'galleryTileSize': galleryTileSize,
        'reopenLast': reopenLast,
        'jsonPaths': jsonPaths,
        'sharedDirs': sharedDirs,
        'chatDirs': chatDirs,
        'me': me,
        'lastChat': lastChat,
      };

  void _fromJson(Map j) {
    try {
      themeMode = ThemeMode.values.byName('${j['themeMode']}');
    } catch (_) {}
    accent = (j['accent'] as num?)?.toInt() ?? accent;
    textScale = (j['textScale'] as num?)?.toDouble() ?? textScale;
    use24h = j['use24h'] as bool? ?? use24h;
    showTimes = j['showTimes'] as bool? ?? showTimes;
    chatImageWidth = (j['chatImageWidth'] as num?)?.toDouble() ?? chatImageWidth;
    galleryTileSize = (j['galleryTileSize'] as num?)?.toDouble() ?? galleryTileSize;
    reopenLast = j['reopenLast'] as bool? ?? reopenLast;
    jsonPaths = (j['jsonPaths'] as List?)?.map((e) => '$e').toList() ?? [];
    sharedDirs = (j['sharedDirs'] as List?)?.map((e) => '$e').toList() ?? [];
    chatDirs = (j['chatDirs'] as Map?)?.map(
          (k, v) => MapEntry('$k', (v as List).map((e) => '$e').toList()),
        ) ??
        {};
    me = '${j['me'] ?? ''}';
    lastChat = '${j['lastChat'] ?? ''}';
  }

  Future<void> load() async {
    try {
      final f = File(filePath);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) _fromJson(j);
      }
    } catch (_) {
      // a damaged or unreadable file just means default settings
    }
  }

  /// Save soon (several quick changes, like dragging a slider, become one write).
  void save() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), _write);
  }

  Future<void> _write() async {
    try {
      final f = File(filePath);
      await f.parent.create(recursive: true);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
    } catch (_) {}
  }

  /// Change a setting, refresh the UI and save.
  void update(void Function() change) {
    change();
    notifyListeners();
    save();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
