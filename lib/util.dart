// Small helpers shared by the screens.

import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'settings.dart';
import 'store.dart';

String two(int n) => n.toString().padLeft(2, '0');

/// Position in [matches] of the next/previous match after [current].
/// Returns -1 when there are no matches; wraps at both ends.
int nextMatchPosition(int? current, List<int> matches, int delta) {
  if (matches.isEmpty) return -1;
  var pos = current == null ? (delta > 0 ? -1 : 0) : matches.indexOf(current);
  if (pos < 0) pos = delta > 0 ? -1 : 0;
  return (pos + delta + matches.length) % matches.length;
}

/// First index in [items] whose timestamp is at or after [target].
/// Items are expected to be sorted by time; no allocation is needed.
int firstIndexAtOrAfter<T>(List<T> items, int target, int Function(T) timeOf) {
  var lo = 0;
  var hi = items.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (timeOf(items[mid]) < target) {
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

/// Monospace text follows the theme's small body style instead of hardcoding
/// one size in every JSON/code preview.
TextStyle monoStyle(BuildContext context) =>
    (Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12))
        .copyWith(fontFamily: 'monospace');

String fmtDate(int? t) {
  if (t == null) return 'Unknown date';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Set once at startup so time formatting follows the "24-hour clock" setting
/// without forcing the whole app to rebuild when only that setting changes.
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

/// Name shown in the UI: the alias if one was set, otherwise the export's name.
String displayName(String name) => gSettings?.aliasFor(name) ?? name;

/// One matcher shared by the in-chat search, the results panel and global search.
bool messageMatches(Msg m, String q, {String? sender, bool mediaOnly = false}) {
  if (sender != null && m.sender != sender) return false;
  if (mediaOnly && m.media.isEmpty) return false;
  if (q.isEmpty) return true;
  final lq = q.toLowerCase();
  return m.lower.contains(lq) ||
      m.sender.toLowerCase().contains(lq) ||
      displayName(m.sender).toLowerCase().contains(lq) ||
      (m.share.isNotEmpty && m.share.toLowerCase().contains(lq)) ||
      m.media.any((x) => x.name.toLowerCase().contains(lq));
}

bool isImagePath(String p) {
  final ext = p.split('.').last.toLowerCase();
  return const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
}

Future<void> openExternal(String path, BuildContext context) async {
  if (!Platform.isLinux) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Opening video and audio on this platform comes in the next step.',
          ),
        ),
      );
    }
    return;
  }
  try {
    final r = await Process.run('xdg-open', [path]);
    if (r.exitCode != 0 && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not open ${path.split(pathSep).last}: ${r.stderr}'.trim(),
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

/// Ask for a folder. On desktop this returns the folder directly. On Android,
/// SAF gives a content:// handle that cannot be walked with dart:io, so fall
/// back to selecting the media files and copying them into a temporary folder
/// that the existing scanner can index.
Future<String?> pickFolder(Store store) async {
  Uri? uri;
  try {
    uri = await FilePicker.pickDirectory();
  } catch (_) {
    uri = null;
  }
  if (uri != null && uri.scheme == 'file') return uri.toFilePath();

  if (uri != null || !Platform.isAndroid) {
    if (uri != null) {
      store.setStatus(
        'Folder handle $uri cannot be scanned on this platform. Pick the files instead.',
      );
    }
    return null;
  }

  final picked = await FilePicker.pickFiles();
  if (picked.isEmpty) return null;
  final dir = await Directory.systemTemp.createTemp('fb_viewer_media_');
  var copied = 0;
  for (final f in picked) {
    final name = safeMediaFileName(f.name);
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    await target.writeAsBytes(await f.readAsBytes());
    copied++;
  }
  store.setStatus(
    'Copied $copied selected media file(s) into a temporary folder for this session.',
  );
  return copied == 0 ? null : dir.path;
}

/// File names from [safeFileName] are used when copying content:// picks.
String safeMediaFileName(String name) {
  final clean = name.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
  return clean.isEmpty ? 'media' : clean;
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
  // Odd Unicode can change the length when lowercased; slicing by the original
  // query length would then cut the wrong characters.
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
