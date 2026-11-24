// Tolerant parser for Facebook / Messenger JSON exports, including the
// end-to-end encrypted ones. It does not rely on one fixed layout: it looks
// for lists of objects that "look like messages" and maps common field names.
//
// Port of the logic in the HTML viewer. No Flutter imports, so it also runs
// in a background isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'models.dart';

const senderKeys = [
  'sender_name',
  'senderName',
  'sender',
  'author',
  'from',
  'user',
  'name',
];
const timeKeys = [
  'timestamp_ms',
  'timestampMs',
  'timestamp',
  'time',
  'date',
  'created_time',
  'createdAt',
  'created_at',
  'sent_at',
  'sentAt',
];
const textKeys = ['content', 'text', 'message', 'body', 'textContent'];
const titleKeys = [
  'title',
  'threadName',
  'thread_name',
  'thread_title',
  'name',
];
const idKeys = ['thread_path', 'threadPath', 'threadId', 'thread_id', 'id'];

// Message IDs, and the many names an export might use for "this message replies to that one".
const msgIdKeys = [
  'message_id',
  'messageId',
  'msg_id',
  'mid',
  'messageID',
  'id',
];
const replyKeys = [
  'reply_to',
  'replyTo',
  'replied_to',
  'repliedTo',
  'reply_to_message',
  'replyToMessage',
  'quoted_message',
  'quotedMessage',
  'quote',
  'reply',
  'parent_message',
  'parentMessage',
];
const replyIdKeys = [
  'reply_to_message_id',
  'replyToMessageId',
  'replied_to_message_id',
  'parent_message_id',
  'parentMessageId',
  'reply_to_id',
  'replyToId',
  'quoted_message_id',
  'quotedMessageId',
];

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
  final u = s.codeUnits;
  var needs = false;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c > 255) return s; // already real Unicode (emoji, CJK, ...)
    // Only decode when a UTF-8 lead byte is followed by a continuation byte,
    // so ordinary Latin-1 letters ("café", "¿qué?") are left alone.
    if ((c == 0xC2 || c == 0xC3 || c == 0xE2 || c == 0xF0) &&
        i + 1 < u.length &&
        u[i + 1] >= 0x80 &&
        u[i + 1] <= 0xBF) {
      needs = true;
      break;
    }
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
        if (v is Map || (v is List && !looksMsgArray(v))) {
          visit(v, node, depth + 1);
        }
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

/// Find out what a message replied to. Exports differ: the reply may be a nested object
/// (with the original text/sender/time) or just the ID of the original message.
Reply? parseReply(Map m) {
  final rid = pick(m, replyIdKeys);
  final rv = pick(m, replyKeys);
  if (rv == null && rid == null) return null;
  if (rv is bool || rv is List) return null;
  if (rv is Map) {
    final tv = pick(rv, textKeys);
    return Reply(
      id: '${pick(rv, msgIdKeys) ?? rid ?? ''}',
      sender: nameOf(pick(rv, senderKeys)),
      text: tv == null ? '' : fixEnc(tv is String ? tv : jsonEncode(tv)),
      t: toMs(pick(rv, timeKeys)),
    );
  }
  if (rid != null) return Reply(id: '$rid');
  final s = '$rv';
  // a bare string: an ID if it looks like one, otherwise the quoted text itself
  if (!s.contains(' ') && s.length < 80) return Reply(id: s);
  return Reply(text: fixEnc(s));
}

Msg normMsg(Map m, {bool keepRaw = true}) {
  final sender = nameOf(pick(m, senderKeys));
  final t = toMs(pick(m, timeKeys));
  final tv = pick(m, textKeys);
  final text = tv == null ? '' : fixEnc(tv is String ? tv : jsonEncode(tv));

  final media = <Media>[];
  for (final k in [
    'photos',
    'videos',
    'audio_files',
    'files',
    'gifs',
    'media',
    'attachments',
    'images',
  ]) {
    final v = m[k];
    if (v is List) {
      for (final x in v) {
        final uri = x is String
            ? x
            : '${pick(x, ['uri', 'url', 'path', 'filename', 'name']) ?? ''}';
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
        reactions.add(
          Reaction(
            fixEnc('${pick(r, ['reaction', 'emoji', 'type']) ?? ''}'),
            nameOf(pick(r, ['actor', 'user', 'name'])),
          ),
        );
      }
    }
  }

  final sv = m['share'];
  final share = sv is Map ? '${sv['link'] ?? sv['url'] ?? ''}' : '';

  return Msg(
    id: '${pick(m, msgIdKeys) ?? ''}',
    reply: parseReply(m),
    sender: sender.isEmpty ? 'Unknown' : sender,
    t: t,
    text: text,
    media: media,
    reactions: reactions,
    share: share,
    type: '${m['type'] ?? ''}',
    unsent:
        m['is_unsent'] == true || m['isUnsent'] == true || m['unsent'] == true,
    // Keeping every original map costs a lot of RAM on 80k+ message exports.
    // "Message details" and raw export still work when this is turned off,
    // they simply show that the original data was not kept.
    raw: keepRaw ? m : const {},
  );
}

List<ParsedThread> parseExport(
  dynamic json,
  String fileName, {
  bool keepRaw = true,
}) {
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
        if (isMsgLike(m)) normMsg(m as Map, keepRaw: keepRaw),
    ];
    if (msgs.isEmpty) continue;

    final tv = pick(meta, titleKeys);
    final title = tv != null
        ? fixEnc('$tv')
        : (parts.isNotEmpty
              ? parts.join(', ')
              : fileName.replaceAll(
                  RegExp(r'\.json$', caseSensitive: false),
                  '',
                ));
    final id = pick(meta, idKeys);
    out.add(ParsedThread(id != null ? '$id' : title, title, parts, msgs));
  }
  return out;
}

// ---- Background work: top-level functions so nothing from the UI gets pulled into the isolate ----

Future<List<ParsedThread>> parseInBackground(
  String path, {
  String? cacheDir,
  bool keepRaw = true,
  bool useCache = true,
}) => Isolate.run(
  () => parseFileCached(
    path,
    cacheDir: cacheDir,
    keepRaw: keepRaw,
    useCache: useCache,
  ),
);

Future<Map<String, String>> scanInBackground(String dir) =>
    Isolate.run(() => scanDir(dir));

/// Read and parse one JSON file. Runs off the UI thread.
List<ParsedThread> parseFile(String path, {bool keepRaw = true}) {
  final text = File(path).readAsStringSync();
  final json = jsonDecode(text);
  return parseExport(json, path.split(pathSep).last, keepRaw: keepRaw);
}

// ---- Persistent parse cache ----
//
// Parsing tens of thousands of messages on every launch is slow. The cache
// stores the normalized form in a flat, predictable JSON layout: decoding that
// is much faster than decoding the original export and running the tolerant
// field-detection code again. The source file's size and modified time are part
// of the cache key, so editing or replacing the export invalidates it.

const cacheVersion = 1;

String _cacheHash(String source) {
  // FNV-1a, enough here because this is only a cache file name (not security).
  var h = 0xcbf29ce484222325;
  for (final c in source.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xffffffffffffffff;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

Map<String, dynamic> _encodeReply(Reply? r) => r == null
    ? const {}
    : <String, dynamic>{
        if (r.id.isNotEmpty) 'i': r.id,
        if (r.sender.isNotEmpty) 's': r.sender,
        if (r.text.isNotEmpty) 'x': r.text,
        if (r.t != null) 't': r.t,
      };

Reply? _decodeReply(Object? v) {
  if (v is! Map || v.isEmpty) return null;
  return Reply(
    id: '${v['i'] ?? ''}',
    sender: '${v['s'] ?? ''}',
    text: '${v['x'] ?? ''}',
    t: v['t'] is num ? (v['t'] as num).toInt() : null,
  );
}

Object _encodeMedia(Media x) => [x.kind, x.uri];

Media _decodeMedia(Object? v) {
  final l = v as List? ?? const [];
  return Media('${l.isEmpty ? '' : l[0]}', '${l.length < 2 ? '' : l[1]}');
}

Object _encodeReaction(Reaction r) => [r.emoji, r.actor];

Reaction _decodeReaction(Object? v) {
  final l = v as List? ?? const [];
  return Reaction('${l.isEmpty ? '' : l[0]}', '${l.length < 2 ? '' : l[1]}');
}

Object _encodeMsg(Msg m, bool keepRaw) => [
  m.id,
  m.sender,
  m.t,
  m.text,
  [for (final x in m.media) _encodeMedia(x)],
  [for (final r in m.reactions) _encodeReaction(r)],
  m.share,
  m.type,
  m.unsent ? 1 : 0,
  _encodeReply(m.reply),
  if (keepRaw) m.raw,
];

Msg _decodeMsg(List l) => Msg(
  id: '${l[0] ?? ''}',
  sender: '${l[1] ?? ''}',
  t: l[2] is num ? (l[2] as num).toInt() : null,
  text: '${l[3] ?? ''}',
  media: [for (final x in (l[4] as List? ?? const [])) _decodeMedia(x)],
  reactions: [for (final r in (l[5] as List? ?? const [])) _decodeReaction(r)],
  share: '${l[6] ?? ''}',
  type: '${l[7] ?? ''}',
  unsent: l[8] == 1,
  reply: _decodeReply(l[9]),
  raw: l.length > 10 && l[10] is Map ? (l[10] as Map) : const {},
);

Object _encodeThreads(List<ParsedThread> threads, bool keepRaw) =>
    <String, dynamic>{
      'v': cacheVersion,
      'threads': [
        for (final t in threads)
          <String, dynamic>{
            'k': t.key,
            'n': t.title,
            'p': t.participants,
            'm': [for (final m in t.messages) _encodeMsg(m, keepRaw)],
          },
      ],
    };

List<ParsedThread> _decodeThreads(Object? value) {
  final root = value as Map?;
  if (root == null || root['v'] != cacheVersion || root['threads'] is! List) {
    throw const FormatException('Unsupported parse cache version');
  }
  final out = <ParsedThread>[];
  for (final t in (root['threads'] as List)) {
    final tm = t as Map;
    out.add(
      ParsedThread(
        '${tm['k'] ?? ''}',
        '${tm['n'] ?? ''}',
        [for (final p in (tm['p'] as List? ?? const [])) '$p'],
        [for (final m in (tm['m'] as List? ?? const [])) _decodeMsg(m as List)],
      ),
    );
  }
  return out;
}

List<ParsedThread> parseFileCached(
  String path, {
  String? cacheDir,
  bool keepRaw = true,
  bool useCache = true,
}) {
  if (!useCache || cacheDir == null) return parseFile(path, keepRaw: keepRaw);

  final stat = File(path).statSync();
  final sig =
      '$cacheVersion|$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}|${keepRaw ? 1 : 0}';
  final file = File('$cacheDir/${_cacheHash(sig)}.json');
  try {
    if (file.existsSync()) {
      return _decodeThreads(jsonDecode(file.readAsStringSync()));
    }
  } catch (_) {
    // Damaged cache: fall through and rebuild it from the original file.
  }

  final threads = parseFile(path, keepRaw: keepRaw);
  try {
    Directory(cacheDir).createSync(recursive: true);
    final tmp = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    tmp.writeAsStringSync(jsonEncode(_encodeThreads(threads, keepRaw)));
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(file.path);
  } catch (_) {
    // Caching is an optimization; never fail to open an export because of it.
  }
  return threads;
}

/// Walk a folder and map lowercase file name -> full path (JSON files are skipped).
Map<String, String> scanDir(String dir) {
  final out = <String, String>{};
  try {
    for (final e in Directory(
      dir,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        final n = e.path.split(pathSep).last.toLowerCase();
        if (!n.endsWith('.json')) out[n] = e.path;
      }
    }
  } catch (_) {
    // keep whatever was found before an unreadable sub-folder
  }
  return out;
}
