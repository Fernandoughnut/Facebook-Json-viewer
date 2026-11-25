// User settings and the remembered session, stored in one small JSON file.
//
// Linux location: $XDG_CONFIG_HOME/fb_viewer/state.json (usually ~/.config/fb_viewer/state.json).
// On Android this will move to the app's private folder in the Android step; until then
// saving there fails silently and the app simply starts fresh each time.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';

/// Where a conversation opens.
enum StartAt { newest, oldest, leftOff }

/// How messages are drawn.
enum ChatLayout { bubbles, compact, plain }

/// How the search results panel lists matches.
enum ResultsLayout { detailed, compact }

/// A saved chat-view filter. Stored by name so it can be reapplied in one click.
class SearchPreset {
  final String name;
  final String query;
  final String sender; // '' means everyone
  final bool mediaOnly;
  final bool regex;
  final bool caseSensitive;
  final String
  sort; // SortMode.name, kept as text to avoid a models.dart dependency

  const SearchPreset({
    required this.name,
    required this.query,
    required this.sender,
    required this.mediaOnly,
    required this.regex,
    required this.caseSensitive,
    required this.sort,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'query': query,
    'sender': sender,
    'mediaOnly': mediaOnly,
    'regex': regex,
    'caseSensitive': caseSensitive,
    'sort': sort,
  };

  factory SearchPreset.fromJson(dynamic j) {
    final m = j is Map ? j : const {};
    return SearchPreset(
      name: '${m['name'] ?? ''}',
      query: '${m['query'] ?? ''}',
      sender: '${m['sender'] ?? ''}',
      mediaOnly: m['mediaOnly'] == true,
      regex: m['regex'] == true,
      caseSensitive: m['caseSensitive'] == true,
      sort: '${m['sort'] ?? 'oldest'}',
    );
  }

  String get summary {
    final bits = <String>[
      if (query.isNotEmpty) '“$query”',
      if (sender.isNotEmpty) sender,
      if (mediaOnly) 'media only',
      if (regex) 'regex',
      if (caseSensitive) 'Aa',
    ];
    return bits.isEmpty ? 'All messages' : bits.join(' · ');
  }
}

Set<String> _stringSet(dynamic value) =>
    value is List ? value.map((e) => '$e').toSet() : <String>{};

T _enumByName<T extends Enum>(List<T> values, dynamic name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

class AppSettings extends ChangeNotifier {
  /// Test hook: override the config folder instead of touching the process env.
  AppSettings({this._configDir});

  final String? _configDir;

  // ---- appearance ----
  ThemeMode themeMode = ThemeMode.system;
  int accent = 0xFF0B7CFF;
  bool material3 = true; // Material 3 components; false keeps the classic look
  bool amoled = false; // pure black background in dark mode
  bool animateTheme =
      false; // smooth color transition, but costly on large chats
  double textScale = 1.0;

  // ---- reading ----
  StartAt startAt = StartAt.newest;
  ChatLayout layout = ChatLayout.bubbles;
  bool showReplies = true;
  bool use24h = true;
  bool showTimes = true;
  double chatImageWidth = 260;
  double galleryTileSize = 140;

  // ---- search / filters ----
  ResultsLayout resultsLayout = ResultsLayout.detailed;
  bool resultsNewestFirst = true;
  List<SearchPreset> presets = [];
  bool showActivityRail = true;
  bool showPeopleFilters = true; // the "Show messages from" / "I am" row

  // ---- performance / privacy ----
  bool useParseCache = true; // reuse normalized messages across launches
  bool keepRaw = true; // turn off to trade "Message details" for lower RAM use
  bool dedupeImports =
      true; // overlapping exports often contain the same messages
  bool lockEnabled = false; // local PIN gate, for shared devices
  String lockHash = ''; // salted SHA-256 of the PIN
  String lockSalt = '';

  // ---- session ----
  bool reopenLast = true;
  List<String> jsonPaths = [];
  List<String> sharedDirs = [];
  Map<String, List<String>> chatDirs = {}; // conversation key -> folders
  Map<String, int> chatPos =
      {}; // conversation key -> time of the message you were reading
  Map<String, String> aliases =
      {}; // original participant name -> friendly name
  Map<String, List<String>> bookmarks = {}; // conversation key -> message keys
  Map<String, String> notes = {}; // 'conversationKey|messageKey' -> note
  Set<String> archivedChats = {}; // hidden from the list until "Show archived"
  Set<String> removedChats =
      {}; // skipped on import/restore; JSON files stay on disk
  String me = '';
  String lastChat = '';

  /// Appearance changes only need the root MaterialApp to rebuild. Keeping them
  /// separate stops theme/accent/text-size changes from rebuilding chat state.
  final ChangeNotifier appearance = ChangeNotifier();

  /// Incremented on every general notification. Stateful views use this to
  /// refresh derived data (for example search hits after an alias is renamed)
  /// without being rebuilt from scratch for appearance-only changes.
  int revision = 0;

  Timer? _timer;
  Future<void> _lastWrite = Future.value();

  String get dir {
    if (_configDir != null) return _configDir;
    final home = Platform.environment['HOME'] ?? '.';
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return '$base/fb_viewer';
  }

  String get filePath => '$dir/state.json';
  String get logPath => '$dir/error.log';
  String get cacheDir => '$dir/cache';

  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  int? _cachedAccent;
  bool? _cachedAmoled;
  bool? _cachedMaterial3;

  /// ThemeData is immutable: regenerate both themes only when their inputs change.
  ThemeData themeFor(Brightness brightness) {
    if (_lightTheme == null ||
        _darkTheme == null ||
        _cachedAccent != accent ||
        _cachedAmoled != amoled ||
        _cachedMaterial3 != material3) {
      _cachedAccent = accent;
      _cachedAmoled = amoled;
      _cachedMaterial3 = material3;
      _lightTheme = _makeTheme(Brightness.light);
      _darkTheme = _makeTheme(Brightness.dark);
    }
    return brightness == Brightness.light ? _lightTheme! : _darkTheme!;
  }

  ThemeData _makeTheme(Brightness b) {
    var cs = ColorScheme.fromSeed(seedColor: Color(accent), brightness: b);
    final black = b == Brightness.dark && amoled;
    if (black) {
      cs = cs.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF0B0B0B),
        surfaceContainer: const Color(0xFF111111),
        surfaceContainerHigh: const Color(0xFF171717),
        surfaceContainerHighest: const Color(0xFF1F1F1F),
      );
    }

    if (material3) {
      return ThemeData(
        colorScheme: cs,
        useMaterial3: true,
        scaffoldBackgroundColor: black ? Colors.black : null,
        appBarTheme: AppBarThemeData(
          backgroundColor: black ? Colors.black : cs.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 1,
          iconTheme: IconThemeData(color: cs.onSurfaceVariant),
          titleTextStyle: TextStyle(
            color: cs.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          color: cs.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: const EdgeInsets.all(8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: cs.outlineVariant),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: cs.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        inputDecorationTheme: InputDecorationThemeData(
          filled: true,
          fillColor: cs.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
        searchBarTheme: SearchBarThemeData(
          backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(1),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(20)),
            ),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: cs.surfaceContainerHighest,
          selectedColor: cs.secondaryContainer,
          side: BorderSide.none,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: cs.outlineVariant,
          thickness: 1,
          space: 1,
        ),
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          selectedColor: cs.onSecondaryContainer,
          selectedTileColor: cs.secondaryContainer,
          iconColor: cs.onSurfaceVariant,
          textColor: cs.onSurface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: black ? Colors.black : cs.surfaceContainerLow,
          elevation: 0,
          groupAlignment: -0.85,
          indicatorColor: cs.secondaryContainer,
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          selectedIconTheme: IconThemeData(color: cs.onSecondaryContainer),
          selectedLabelTextStyle: TextStyle(
            color: cs.onSurface,
            fontWeight: FontWeight.w600,
          ),
          unselectedIconTheme: IconThemeData(color: cs.onSurfaceVariant),
          unselectedLabelTextStyle: TextStyle(color: cs.onSurfaceVariant),
        ),
        progressIndicatorTheme: ProgressIndicatorThemeData(
          color: cs.primary,
          linearTrackColor: cs.secondaryContainer,
          linearMinHeight: 3,
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: cs.inverseSurface,
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: TextStyle(color: cs.onInverseSurface, fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
      );
    }

    return ThemeData(
      colorScheme: cs,
      useMaterial3: false,
      scaffoldBackgroundColor: black ? Colors.black : null,
      cardTheme: CardThemeData(
        color: black ? cs.surface : null,
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: black ? cs.surface : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        border: const OutlineInputBorder(),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode.name,
    'accent': accent,
    'material3': material3,
    'amoled': amoled,
    'animateTheme': animateTheme,
    'textScale': textScale,
    'startAt': startAt.name,
    'layout': layout.name,
    'showReplies': showReplies,
    'use24h': use24h,
    'showTimes': showTimes,
    'chatImageWidth': chatImageWidth,
    'galleryTileSize': galleryTileSize,
    'resultsLayout': resultsLayout.name,
    'resultsNewestFirst': resultsNewestFirst,
    'searchPresets': [for (final p in presets) p.toJson()],
    'showActivityRail': showActivityRail,
    'showPeopleFilters': showPeopleFilters,
    'useParseCache': useParseCache,
    'keepRaw': keepRaw,
    'dedupeImports': dedupeImports,
    'lockEnabled': lockEnabled,
    'lockHash': lockHash,
    'lockSalt': lockSalt,
    'reopenLast': reopenLast,
    'jsonPaths': jsonPaths,
    'sharedDirs': sharedDirs,
    'chatDirs': chatDirs,
    'chatPos': chatPos,
    'aliases': aliases,
    'bookmarks': bookmarks,
    'notes': notes,
    'archivedChats': archivedChats.toList(),
    'removedChats': removedChats.toList(),
    'me': me,
    'lastChat': lastChat,
  };

  void _fromJson(Map j) {
    themeMode = _enumByName(ThemeMode.values, j['themeMode'], themeMode);
    accent = (j['accent'] as num?)?.toInt() ?? accent;
    material3 = j['material3'] as bool? ?? material3;
    amoled = j['amoled'] as bool? ?? amoled;
    animateTheme = j['animateTheme'] as bool? ?? animateTheme;
    textScale = (j['textScale'] as num?)?.toDouble() ?? textScale;
    startAt = _enumByName(StartAt.values, j['startAt'], startAt);
    layout = _enumByName(ChatLayout.values, j['layout'], layout);
    showReplies = j['showReplies'] as bool? ?? showReplies;
    use24h = j['use24h'] as bool? ?? use24h;
    showTimes = j['showTimes'] as bool? ?? showTimes;
    chatImageWidth =
        (j['chatImageWidth'] as num?)?.toDouble() ?? chatImageWidth;
    galleryTileSize =
        (j['galleryTileSize'] as num?)?.toDouble() ?? galleryTileSize;
    resultsLayout = _enumByName(
      ResultsLayout.values,
      j['resultsLayout'],
      resultsLayout,
    );
    resultsNewestFirst = j['resultsNewestFirst'] as bool? ?? resultsNewestFirst;
    showActivityRail = j['showActivityRail'] as bool? ?? showActivityRail;
    showPeopleFilters = j['showPeopleFilters'] as bool? ?? showPeopleFilters;
    final presetsJson = j['searchPresets'];
    presets = presetsJson is List
        ? presetsJson
              .whereType<Map>()
              .map((e) => SearchPreset.fromJson(e))
              .where((p) => p.name.isNotEmpty)
              .toList()
        : <SearchPreset>[];
    useParseCache = j['useParseCache'] as bool? ?? useParseCache;
    keepRaw = j['keepRaw'] as bool? ?? keepRaw;
    dedupeImports = j['dedupeImports'] as bool? ?? dedupeImports;
    lockEnabled = j['lockEnabled'] as bool? ?? lockEnabled;
    lockHash = '${j['lockHash'] ?? ''}';
    lockSalt = '${j['lockSalt'] ?? ''}';
    if (lockEnabled && (lockHash.isEmpty || lockSalt.isEmpty)) {
      lockEnabled = false;
    }
    reopenLast = j['reopenLast'] as bool? ?? reopenLast;
    jsonPaths = (j['jsonPaths'] as List?)?.map((e) => '$e').toList() ?? [];
    sharedDirs = (j['sharedDirs'] as List?)?.map((e) => '$e').toList() ?? [];
    final dirs = <String, List<String>>{};
    final dj = j['chatDirs'];
    if (dj is Map) {
      for (final e in dj.entries) {
        if (e.value is List) {
          dirs['${e.key}'] = (e.value as List).map((x) => '$x').toList();
        }
      }
    }
    chatDirs = dirs;
    archivedChats = _stringSet(j['archivedChats']);
    removedChats = _stringSet(j['removedChats']);

    // A hand-edited or half-written state file must not throw away every setting.
    final pos = <String, int>{};
    final pj = j['chatPos'];
    if (pj is Map) {
      for (final e in pj.entries) {
        final v = e.value is num
            ? (e.value as num).toInt()
            : num.tryParse('${e.value}')?.toInt();
        if (v != null) pos['${e.key}'] = v;
      }
    }
    chatPos = pos;

    final al = <String, String>{};
    final aj = j['aliases'];
    if (aj is Map) {
      for (final e in aj.entries) {
        final v = '${e.value}'.trim();
        if (v.isNotEmpty) al['${e.key}'] = v;
      }
    }
    aliases = al;

    final bm = <String, List<String>>{};
    final bj = j['bookmarks'];
    if (bj is Map) {
      for (final e in bj.entries) {
        if (e.value is List) {
          bm['${e.key}'] = (e.value as List).map((x) => '$x').toList();
        }
      }
    }
    bookmarks = bm;

    final nt = <String, String>{};
    final nj = j['notes'];
    if (nj is Map) {
      for (final e in nj.entries) {
        final v = '${e.value}';
        if (v.isNotEmpty) nt['${e.key}'] = v;
      }
    }
    notes = nt;
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
    _timer = Timer(const Duration(milliseconds: 400), _enqueueWrite);
  }

  /// Write now. Called when the app is backgrounded/closed and after a PIN reset.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _enqueueWrite();
  }

  Future<void> _enqueueWrite() {
    // Serialize writes so a debounced save cannot race with a lifecycle flush.
    final next = _lastWrite.then(
      (_) => _writeNow(),
      onError: (_) => _writeNow(),
    );
    _lastWrite = next;
    return next;
  }

  Future<void> _writeNow() async {
    try {
      final f = File(filePath);
      await f.parent.create(recursive: true);
      // Write to a temporary file first: a crash mid-write must not leave a
      // half-written state.json that looks like default settings on next run.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(toJson()),
      );
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    revision++;
    super.notifyListeners();
  }

  /// Change a setting, refresh the UI and save.
  /// [appearanceOnly] limits the rebuild to the root theme/text-scaler widget.
  void update(void Function() change, {bool appearanceOnly = false}) {
    change();
    if (appearanceOnly) {
      appearance.notifyListeners();
    } else {
      notifyListeners();
    }
    save();
  }

  /// Friendly name for a participant, falling back to the name in the export.
  String aliasFor(String name) => aliases[name] ?? name;

  void setAlias(String original, String alias) {
    final v = alias.trim();
    update(() {
      if (v.isEmpty) {
        aliases.remove(original);
      } else {
        aliases[original] = v;
      }
    });
  }

  /// Save with a stable name: re-saving replaces instead of duplicating.
  void savePreset(SearchPreset preset) => update(() {
    presets.removeWhere((p) => p.name == preset.name);
    presets.add(preset);
    if (presets.length > 50) presets.removeAt(0);
  });

  void deletePreset(String name) =>
      update(() => presets.removeWhere((p) => p.name == name));

  /// The PIN is stored only as a salted hash, never in plain text. This is a
  /// convenient local gate for a shared desktop, not encryption of the export.
  bool pinMatches(String pin) {
    if (!lockEnabled || lockHash.isEmpty || lockSalt.isEmpty) return true;
    final hash = sha256.convert(utf8.encode('$lockSalt|$pin')).toString();
    return hash == lockHash;
  }

  void setPin(String pin) {
    final salt = DateTime.now().microsecondsSinceEpoch.toString();
    lockSalt = salt;
    lockHash = sha256.convert(utf8.encode('$salt|$pin')).toString();
    lockEnabled = true;
    update(() {});
  }

  void disableLock() => update(() {
    lockEnabled = false;
    lockHash = '';
    lockSalt = '';
  });

  /// Removes the local gate for someone who forgot their PIN. The UI must ask
  /// for confirmation first; this never encrypts or changes the export files.
  Future<void> resetPin() async {
    disableLock();
    await flush();
  }

  void clearParseCache() {
    try {
      final d = Directory(cacheDir);
      if (d.existsSync()) {
        for (final e in d.listSync()) {
          if (e is File &&
              (e.path.endsWith('.json') || e.path.endsWith('.tmp'))) {
            e.deleteSync();
          }
        }
      }
    } catch (_) {}
  }

  String readLog() {
    try {
      final f = File(logPath);
      return f.existsSync() ? f.readAsStringSync() : '';
    } catch (_) {
      return '';
    }
  }

  void clearLog() {
    try {
      File(logPath).writeAsStringSync('');
    } catch (_) {}
  }

  /// Append a line to the error log, keeping it bounded.
  void _appendLog(String line) {
    try {
      final f = File(logPath);
      f.parent.createSync(recursive: true);
      if (f.existsSync() && f.lengthSync() > 512 * 1024) {
        f.writeAsStringSync('');
      }
      f.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Append an error to the log file, so a crash can be looked at afterwards.
  void logError(String text) {
    _appendLog('${DateTime.now().toIso8601String()}\n$text\n');
  }

  /// Record the last user action synchronously. Native aborts bypass Dart's
  /// error handlers, so this breadcrumb is often all that survives a crash.
  void logBreadcrumb(String text) {
    _appendLog('${DateTime.now().toIso8601String()} [breadcrumb] $text');
  }

  @override
  void dispose() {
    _timer?.cancel();
    appearance.dispose();
    super.dispose();
  }
}
