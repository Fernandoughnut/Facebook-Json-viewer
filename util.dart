// Small helpers shared by the screens.

import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'store.dart';

String two(int n) => n.toString().padLeft(2, '0');

String fmtDate(int? t) {
  if (t == null) return 'Unknown date';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Mirrors the "24-hour clock" setting (set by the app whenever settings change).
bool gUse24h = true;

String fmtTime(int? t) {
  if (t == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  if (gUse24h) return '${two(d.hour)}:${two(d.minute)}';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
}

bool sameDay(int? a, int? b) {
  if (a == null || b == null) return a == b;
  final x = DateTime.fromMillisecondsSinceEpoch(a);
  final y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

bool isImagePath(String p) {
  final ext = p.split('.').last.toLowerCase();
  return const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
}

Future<void> openExternal(String path, BuildContext context) async {
  if (!Platform.isLinux) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opening video and audio on this platform comes in the next step.')),
      );
    }
    return;
  }
  try {
    final r = await Process.run('xdg-open', [path]);
    if (r.exitCode != 0 && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${path.split(pathSep).last}: ${r.stderr}'.trim())),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot open file: $e')));
    }
  }
}

/// Ask for a folder. Returns a normal path, or null if cancelled / not supported yet.
Future<String?> pickFolder(Store store) async {
  final uri = await FilePicker.pickDirectory();
  if (uri == null) return null;
  if (uri.scheme != 'file') {
    // On Android this is a content:// folder handle; real folder support is the next step.
    store.setStatus('This platform returned a folder handle ($uri). Android folder access is not built yet.');
    return null;
  }
  return uri.toFilePath();
}

/// Splits [text] into spans with every occurrence of [q] highlighted (case-insensitive).
List<InlineSpan> highlightSpans(String text, String q, TextStyle? base, Color hl) {
  if (q.isEmpty) return [TextSpan(text: text, style: base)];
  final lt = text.toLowerCase();
  final lq = q.toLowerCase();
  if (lt.length != text.length) return [TextSpan(text: text, style: base)]; // odd Unicode: skip highlighting
  final out = <InlineSpan>[];
  var pos = 0;
  while (true) {
    final i = lt.indexOf(lq, pos);
    if (i < 0) break;
    if (i > pos) out.add(TextSpan(text: text.substring(pos, i), style: base));
    out.add(TextSpan(
      text: text.substring(i, i + q.length),
      style: (base ?? const TextStyle()).copyWith(backgroundColor: hl, color: Colors.black),
    ));
    pos = i + q.length;
  }
  if (pos < text.length) out.add(TextSpan(text: text.substring(pos), style: base));
  return out;
}

/// A short piece of [text] around the first match, for the results list.
String snippet(String text, String q) {
  final i = text.toLowerCase().indexOf(q.toLowerCase());
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
