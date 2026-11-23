// Tolerant parser for Facebook / Messenger JSON exports, including the
// end-to-end encrypted ones. It does not rely on one fixed layout: it looks
// for lists of objects that "look like messages" and maps common field names.
//
// Port of the logic in the HTML viewer. No Flutter imports, so it also runs
// in a background isolate.

import 'dart:convert';
import 'dart:io';

import 'models.dart';

const senderKeys = ['sender_name', 'senderName', 'sender', 'author', 'from', 'user', 'name'];
const timeKeys = [
  'timestamp_ms', 'timestampMs', 'timestamp', 'time', 'date',
  'created_time', 'createdAt', 'created_at', 'sent_at', 'sentAt',
];
const textKeys = ['content', 'text', 'message', 'body', 'textContent'];
const titleKeys = ['title', 'threadName', 'thread_name', 'thread_title', 'name'];
const idKeys = ['thread_path', 'threadPath', 'threadId', 'thread_id', 'id'];

dynamic pick(dynamic o, List<String> keys) {
  if (o is! Map) return null;
  for (final k in keys) {
    final v = o[k];
    if (v != null && v != '') return v;
  }
  return null;
}

/// Older Facebook exports store UTF-8 bytes as Latin-1 characters ("Ã©" instead of "é").
/// Undo that when it is safe to do so.
String fixEnc(String s) {
  var needs = false;
  for (final c in s.codeUnits) {
    if (c > 255) return s;
    if (c >= 0x80) needs = true;
  }
  if (!needs) return s;
  try {
    return utf8.decode(latin1.encode(s));
  } catch (_) {
    return s;
  }
}

int? toMs(dynamic v) {
  if (v is num) {
    final n = v.toDouble();
    return (n < 1e11 ? n * 1000 : n).round();
  }
  if (v is String) {
    final s = v.trim();
    final n = num.tryParse(s);
    if (n != null) {
      final d = n.toDouble();
      return (d < 1e11 ? d * 1000 : d).round();
    }
    return DateTime.tryParse(s)?.millisecondsSinceEpoch;
  }
  return null;
}

bool isMsgLike(dynamic o) {
  if (o is! Map) return false;
  final hasTime = toMs(pick(o, timeKeys)) != null;
  final hasSender = pick(o, senderKeys) != null;
  final hasText = pick(o, textKeys) != null;
  return hasTime && (hasSender || hasText);
}

bool looksMsgArray(dynamic a) {
  if (a is! List || a.isEmpty) return false;
  final sample = a.take(8).toList();
  final good = sample.where(isMsgLike).length;
  return good >= (sample.length / 2).ceil();
}

class RawThread {
  final Map meta;
  final List messages;
  RawThread(this.meta, this.messages);
}

List<RawThread> findThreads(dynamic root) {
  final out = <RawThread>[];
  void visit(dynamic node, Map ctx, int depth) {
    if (depth > 8) return;
    if (node is List) {
      if (looksMsgArray(node)) {
        out.add(RawThread(ctx, node));
        return;
      }
      for (final n in node) {
        visit(n, ctx, depth + 1);
      }
      return;
    }
    if (node is Map) {
      for (final v in node.values) {
        if (v is List && looksMsgArray(v)) out.add(RawThread(node, v));
      }
      for (final v in node.values) {
        if (v is Map || (v is List && !looksMsgArray(v))) visit(v, node, depth + 1);
      }
    }
  }

  visit(root, const {}, 0);
  return out;
}

String nameOf(dynamic x) {
  if (x == null) return '';
  if (x is String) return fixEnc(x);
  if (x is Map) {
    final v = pick(x, ['name', 'full_name', 'fullName', 'display_name', 'id']);
    return v == null ? '' : fixEnc('$v');
  }
  return fixEnc('$x');
}

Msg normMsg(Map m) {
  final sender = nameOf(pick(m, senderKeys));
  final t = toMs(pick(m, timeKeys));
  final tv = pick(m, textKeys);
  final text = tv == null ? '' : fixEnc(tv is String ? tv : jsonEncode(tv));

  final media = <Media>[];
  for (final k in ['photos', 'videos', 'audio_files', 'files', 'gifs', 'media', 'attachments', 'images']) {
    final v = m[k];
    if (v is List) {
      for (final x in v) {
        final uri = x is String ? x : '${pick(x, ['uri', 'url', 'path', 'filename', 'name']) ?? ''}';
        media.add(Media(k, uri));
      }
    }
  }
  final st = m['sticker'];
  if (st is Map) media.add(Media('sticker', '${st['uri'] ?? ''}'));

  final reactions = <Reaction>[];
  final rx = m['reactions'];
  if (rx is List) {
    for (final r in rx) {
      if (r is String) {
        reactions.add(Reaction(fixEnc(r), ''));
      } else {
        reactions.add(Reaction(
          fixEnc('${pick(r, ['reaction', 'emoji', 'type']) ?? ''}'),
          nameOf(pick(r, ['actor', 'user', 'name'])),
        ));
      }
    }
  }

  final sv = m['share'];
  final share = sv is Map ? '${sv['link'] ?? sv['url'] ?? ''}' : '';

  return Msg(
    sender: sender.isEmpty ? 'Unknown' : sender,
    t: t,
    text: text,
    media: media,
    reactions: reactions,
    share: share,
    type: '${m['type'] ?? ''}',
    unsent: m['is_unsent'] == true || m['isUnsent'] == true || m['unsent'] == true,
    raw: m,
  );
}

List<ParsedThread> parseExport(dynamic json, String fileName) {
  final out = <ParsedThread>[];
  for (final f in findThreads(json)) {
    final meta = f.meta;
    final parts = <String>[];
    final pv = meta['participants'];
    if (pv is List) {
      for (final p in pv) {
        final n = nameOf(p);
        if (n.isNotEmpty) parts.add(n);
      }
    }
    final msgs = <Msg>[
      for (final m in f.messages)
        if (isMsgLike(m)) normMsg(m as Map),
    ];
    if (msgs.isEmpty) continue;

    final tv = pick(meta, titleKeys);
    final title = tv != null
        ? fixEnc('$tv')
        : (parts.isNotEmpty
            ? parts.join(', ')
            : fileName.replaceAll(RegExp(r'\.json$', caseSensitive: false), ''));
    final id = pick(meta, idKeys);
    out.add(ParsedThread(id != null ? '$id' : title, title, parts, msgs));
  }
  return out;
}

// ---- Functions meant to run inside Isolate.run (they only take simple arguments) ----

/// Read and parse one JSON file. Runs off the UI thread.
List<ParsedThread> parseFile(String path) {
  final text = File(path).readAsStringSync();
  final json = jsonDecode(text);
  return parseExport(json, path.split(RegExp(r'[\\/]')).last);
}

/// Walk a folder and map lowercase file name -> full path (JSON files are skipped).
Map<String, String> scanDir(String dir) {
  final out = <String, String>{};
  try {
    for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        final n = e.path.split(RegExp(r'[\\/]')).last.toLowerCase();
        if (!n.endsWith('.json')) out[n] = e.path;
      }
    }
  } catch (_) {
    // keep whatever was found before an unreadable sub-folder
  }
  return out;
}
