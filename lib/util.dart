// Small helpers shared by the screens.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'android_folder.dart';
import 'models.dart';
import 'settings.dart';
import 'store.dart';

String two(int n) => n.toString().padLeft(2, '0');

/// Group digits for counters such as "20,000+ matches".
String formatCount(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// Stable PageStorage identity for a conversation's search results list.
/// The same key restores a scrolled position; any change starts at the top.
String searchResultsStorageKey({
  required String chatKey,
  required String query,
  required String? sender,
  required bool mediaOnly,
  required bool useRegex,
  required bool caseSensitive,
  required SortMode sort,
  required bool newestFirst,
  required ResultsLayout layout,
  required int count,
}) {
  final parts = <String>[
    chatKey,
    query,
    sender ?? '',
    mediaOnly.toString(),
    useRegex.toString(),
    caseSensitive.toString(),
    sort.name,
    newestFirst.toString(),
    layout.name,
    count.toString(),
  ];
  return parts.map((p) => '${p.length}:$p').join('|');
}

/// Next/previous match position; -1 when none, wrapping at both ends.
int nextMatchPosition(int? current, List<int> matches, int delta) {
  if (matches.isEmpty) return -1;
  var pos = current == null ? (delta > 0 ? -1 : 0) : matches.indexOf(current);
  if (pos < 0) pos = delta > 0 ? -1 : 0;
  return (pos + delta + matches.length) % matches.length;
}

/// First index in reading order at or after [target] in a time-sorted list.
/// With [descending], the list is newest-first.
int firstIndexAtOrAfter<T>(
  List<T> items,
  int target,
  int Function(T) timeOf, {
  bool descending = false,
}) {
  var lo = 0;
  var hi = items.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    final t = timeOf(items[mid]);
    final beforeTarget = descending ? t > target : t < target;
    if (beforeTarget) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// One place to tune search highlights (and their readable foreground).
const Color kHighlightColor = Color(0xFFFFC107); // Amber 500
const Color kHighlightOnColor = Colors.black;

/// Monospace text follows the theme's small body style.
TextStyle monoStyle(BuildContext context) =>
    (Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12))
        .copyWith(fontFamily: 'monospace');

String fmtDate(int? t) {
  if (t == null) return 'Unknown date';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Set once at startup so time formatting follows the 24-hour setting.
AppSettings? gSettings;

String fmtTime(int? t) {
  if (t == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  if (gSettings?.use24h ?? true) return '${two(d.hour)}:${two(d.minute)}';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
}

bool sameDay(int? a, int? b) {
  if (a == null || b == null) return a == b;
  final x = DateTime.fromMillisecondsSinceEpoch(a);
  final y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// True when two timestamps fall in the same wall-clock minute.
bool sameMinute(int? a, int? b) {
  if (a == null || b == null) return a == b;
  return a ~/ 60000 == b ~/ 60000;
}

/// Immersive mode reveals its overlay position bar only for fast scrolls.
const double kFastScrollPxPerSecond = 900;

/// Measure velocity over a short window because fling notifications are sparse.
const Duration kFastScrollWindow = Duration(milliseconds: 200);

/// Require sustained fast scrolling before revealing the position bar.
const Duration kFastScrollHold = Duration(milliseconds: 400);

bool isFastScroll(double deltaPx, int elapsedMs) {
  if (elapsedMs <= 0) return false;
  return (deltaPx.abs() * 1000) / elapsedMs >= kFastScrollPxPerSecond;
}

/// Tracks scroll velocity without Flutter widgets so the rule is testable.
class FastScrollTracker {
  FastScrollTracker({
    this.window = kFastScrollWindow,
    this.hold = kFastScrollHold,
  });

  final Duration window;
  final Duration hold;

  final List<({int t, double px})> _samples = <({int t, double px})>[];
  int? _fastSince;
  bool _revealed = false;

  /// Returns true once per sustained fast burst, when [hold] has elapsed.
  bool update(int now, double pixels) {
    _samples.add((t: now, px: pixels));
    while (_samples.length > 1 &&
        now - _samples.first.t > window.inMilliseconds) {
      _samples.removeAt(0);
    }

    final first = _samples.first;
    final elapsed = now - first.t;
    final fast =
        _samples.length > 1 &&
        elapsed > 0 &&
        isFastScroll(pixels - first.px, elapsed);
    if (!fast) {
      _fastSince = null;
      _revealed = false;
      return false;
    }

    _fastSince ??= now;
    if (!_revealed && now - _fastSince! >= hold.inMilliseconds) {
      _revealed = true;
      return true;
    }
    return false;
  }

  /// Clears the burst state, e.g. when scrolling ends or immersive mode exits.
  void reset() {
    _samples.clear();
    _fastSince = null;
    _revealed = false;
  }
}

/// A scroll dismisses floating controls unless an open menu is active.
bool shouldAutoHideImmersiveControls({
  required bool enabled,
  required bool menuOpen,
  required bool visible,
  required bool queryActive,
  required bool searchFocused,
  required bool selecting,
}) =>
    enabled &&
    !menuOpen &&
    visible &&
    !queryActive &&
    !searchFocused &&
    !selecting;

/// Name shown in the UI: the alias if one was set, otherwise the export's name.
String displayName(String name) => gSettings?.aliasFor(name) ?? name;

/// One matcher shared by the in-chat search, the results panel and global search.
bool messageMatches(Msg m, String q, {String? sender, bool mediaOnly = false}) {
  if (sender != null && m.sender != sender) return false;
  if (mediaOnly && m.media.isEmpty) return false;
  if (q.isEmpty) return true;
  final lq = q.toLowerCase();
  final alias = gSettings?.lowerAliasFor(m.sender) ?? m.lowerSender;
  return m.lower.contains(lq) ||
      m.lowerSender.contains(lq) ||
      alias.contains(lq) ||
      (m.lowerShare.isNotEmpty && m.lowerShare.contains(lq)) ||
      m.lowerMediaNames.any((name) => name.contains(lq));
}

/// HTTP(S) links open in the browser; local media playback stays Linux-only.
bool isWebLink(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

bool isImagePath(String p) {
  final ext = p.split('.').last.toLowerCase();
  return const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
}

Future<void> openExternal(String target, BuildContext context) async {
  // Links are the common case on Android: ACTION_VIEW with an http(s) Uri
  // opens the browser. Local media remains Linux-only because app-private file
  // paths are not readable by other Android apps without a content provider.
  if (Platform.isAndroid && isWebLink(target)) {
    final opened = await AndroidFolderPicker.openLink(target);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No browser could open that link.')),
      );
    }
    return;
  }
  if (!Platform.isLinux) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Opening local files is supported on Linux. Links open in a browser.',
          ),
        ),
      );
    }
    return;
  }
  try {
    final r = await Process.run('xdg-open', [target]);
    if (r.exitCode != 0 && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not open ${target.split(pathSep).last}: ${r.stderr}'.trim(),
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Cannot open file: $e')));
    }
  }
}

/// Android SAF trees are copied into app-private storage because dart:io cannot walk them.
Future<String?> pickFolder(Store store, {NavigatorState? navigator}) async {
  if (Platform.isAndroid) {
    final uri = await AndroidFolderPicker.pick();
    if (uri == null) return null;
    final dir = Directory(
      '${store.settings.mediaDir}${Platform.pathSeparator}'
      '${AndroidFolderPicker.folderNameFor(uri)}',
    );
    final existedBefore = dir.existsSync();
    await dir.create(recursive: true);

    // Show progress so a large SAF import does not look frozen. Keep the route
    // so the dialog can be removed without popping an unrelated screen.
    final progress = ValueNotifier<Map<String, dynamic>>(
      const <String, dynamic>{},
    );
    DialogRoute<void>? dialog;
    if (navigator != null && navigator.mounted) {
      dialog = DialogRoute<void>(
        context: navigator.context,
        barrierDismissible: false,
        builder: (_) => _FolderImportDialog(progress: progress),
      );
      unawaited(navigator.push(dialog));
    }
    store.setStatus('Importing folder… Large folders can take a few minutes.');
    Future<void> discardIfNew() async {
      if (!shouldDiscardImportDir(existedBefore: existedBefore)) return;
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        store.settings.logError('Could not clean up folder import: $e');
      }
    }

    try {
      final result = await AndroidFolderPicker.import(
        uri,
        dir.path,
        onProgress: (p) => progress.value = p,
      );
      final error = result['error'];
      if (error != null) {
        await discardIfNew();
        store.settings.logError('Folder import failed: $error');
        store.setStatus('Could not import that folder: $error');
        return null;
      }
      if (result['cancelled'] == true) {
        await discardIfNew();
        store.setStatus('Folder import cancelled.');
        return null;
      }
      final copied = result['copied'] as int? ?? 0;
      final skipped = result['skipped'] as int? ?? 0;
      if (copied == 0 && skipped == 0) {
        await discardIfNew();
        store.setStatus('No photos or videos were found in that folder.');
        return null;
      }
      store.setStatus(
        'Imported $copied media file(s) from the folder'
        '${skipped > 0 ? ' ($skipped already present or unreadable)' : ''}.',
      );
      return dir.path;
    } catch (e) {
      await discardIfNew();
      store.settings.logError('Folder import failed: $e');
      store.setStatus('Could not import that folder: $e');
      return null;
    } finally {
      if (dialog != null &&
          dialog.isActive &&
          navigator != null &&
          navigator.mounted) {
        navigator.removeRoute(dialog);
      }
      progress.dispose();
    }
  }

  Uri? uri;
  try {
    uri = await FilePicker.pickDirectory();
  } catch (e) {
    store.settings.logError('Folder picker failed: $e');
    store.setStatus('Could not open the folder picker: $e');
    return null;
  }
  if (uri != null && uri.scheme == 'file') return uri.toFilePath();
  if (uri != null) {
    store.setStatus(
      'Folder handle $uri cannot be scanned on this platform. Pick the files instead.',
    );
  }
  return null;
}

class _FolderImportDialog extends StatelessWidget {
  final ValueNotifier<Map<String, dynamic>> progress;
  const _FolderImportDialog({required this.progress});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope<Object?>(
      canPop: false,
      child: AlertDialog(
        title: const Text('Importing media folder'),
        content: ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: progress,
          builder: (context, p, _) {
            final total = p['total'] as int? ?? 0;
            final current = p['current'] as int? ?? 0;
            final copied = p['copied'] as int? ?? 0;
            final name = p['name'] as String?;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: total > 0 ? current / total : null,
                ),
                const SizedBox(height: 12),
                Text(
                  total > 0
                      ? '$current of $total files checked'
                      : 'Listing files in the folder…',
                ),
                const SizedBox(height: 4),
                Text('$copied copied so far'),
                if (name != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => unawaited(AndroidFolderPicker.cancelImport()),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// All .json files under a folder, recursively. Used for bulk import.
List<String> jsonFilesIn(String dir) {
  final out = <String>[];
  try {
    for (final e in Directory(
      dir,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is File && e.path.toLowerCase().endsWith('.json')) out.add(e.path);
    }
  } catch (_) {}
  return out..sort();
}

/// Splits [text] into spans with every occurrence of [q] highlighted (case-insensitive).
List<InlineSpan> highlightSpans(
  String text,
  String q,
  TextStyle? base,
  Color hl, {
  bool caseSensitive = false,
}) {
  if (q.isEmpty) return [TextSpan(text: text, style: base)];
  final lt = caseSensitive ? text : text.toLowerCase();
  final lq = caseSensitive ? q : q.toLowerCase();
  // Lowercasing Unicode can change length; slice using the original offsets.
  if (!caseSensitive && (lt.length != text.length || lq.length != q.length)) {
    return [TextSpan(text: text, style: base)];
  }
  final out = <InlineSpan>[];
  var pos = 0;
  while (true) {
    final i = lt.indexOf(lq, pos);
    if (i < 0) break;
    if (i > pos) out.add(TextSpan(text: text.substring(pos, i), style: base));
    out.add(
      TextSpan(
        text: text.substring(i, i + q.length),
        style: (base ?? const TextStyle()).copyWith(
          backgroundColor: hl,
          color: kHighlightOnColor,
        ),
      ),
    );
    pos = i + q.length;
  }
  if (pos < text.length) {
    out.add(TextSpan(text: text.substring(pos), style: base));
  }
  return out;
}

/// A short piece of [text] around the first match, for the results list.
String snippet(String text, String q, {bool caseSensitive = false}) {
  final lower = caseSensitive ? text : text.toLowerCase();
  final lq = caseSensitive ? q : q.toLowerCase();
  // Offsets from a lowered string cannot be used to slice the original text.
  if (!caseSensitive &&
      (lower.length != text.length || lq.length != q.length)) {
    return text;
  }
  final i = lower.indexOf(lq);
  if (i < 0 || text.length <= 140) return text;
  final start = math.max(0, i - 40);
  final end = math.min(text.length, i + q.length + 90);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}

class Pic {
  final String path;
  final String caption;
  const Pic(this.path, this.caption);
}
