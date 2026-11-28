// Tolerant parser for Facebook / Messenger JSON exports, including encrypted ones.
// No Flutter imports, so it also runs in a background isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

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
const mediaKeys = [
  'photos',
  'videos',
  'audio_files',
  'files',
  'gifs',
  'media',
  'attachments',
  'images',
];
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

/// Repair UTF-8 bytes misread as Latin-1 when it is safe to do so.
///
/// Runs are decoded individually so a string can mix real Unicode (an emoji,
/// for example) with mojibake from CJK, Cyrillic or Greek text.
String fixEnc(String s) {
  final u = s.codeUnits;
  final out = StringBuffer();
  var changed = false;
  var i = 0;
  while (i < u.length) {
    final lead = u[i];
    var length = 0;
    if (lead >= 0xC2 && lead <= 0xDF) {
      length = 2;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
      length = 3;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
      length = 4;
    }
    var decoded = '';
    if (length > 0 && i + length <= u.length) {
      var valid = true;
      for (var j = 1; j < length; j++) {
        final b = u[i + j];
        if (b < 0x80 || b > 0xBF) {
          valid = false;
          break;
        }
      }
      if (valid) {
        final raw = String.fromCharCodes(u.getRange(i, i + length));
        try {
          decoded = utf8.decode(latin1.encode(raw));
        } catch (_) {
          decoded = '';
        }
        if (decoded == raw) decoded = '';
      }
    }
    if (decoded.isNotEmpty) {
      out.write(decoded);
      changed = true;
      i += length;
    } else {
      out.writeCharCode(lead);
      i++;
    }
  }
  return changed ? out.toString() : s;
}

int? toMs(dynamic v) => toMsWithHint(v, null);

/// [key] lets explicit *_ms fields keep their units; only ambiguous numeric
/// fields large enough to be microseconds are divided by 1000.
int? toMsWithHint(dynamic v, String? key) {
  if (v is num) return _numToMs(v.toDouble(), key);
  if (v is String) {
    final s = v.trim();
    final n = num.tryParse(s);
    if (n != null) return _numToMs(n.toDouble(), key);
    return DateTime.tryParse(s)?.millisecondsSinceEpoch;
  }
  return null;
}

int? _numToMs(double d, String? key) {
  final explicitlyMs =
      key != null &&
      (key.endsWith('_ms') || key.endsWith('Ms') || key.endsWith('MS'));
  if (explicitlyMs) return d.round();
  if (d >= 1e14) return (d / 1000).round();
  if (d < 1e11) return (d * 1000).round();
  return d.round();
}

({String key, dynamic value})? pickWithKey(dynamic o, List<String> keys) {
  if (o is! Map) return null;
  for (final k in keys) {
    final v = o[k];
    if (v != null && v != '') return (key: k, value: v);
  }
  return null;
}

int? timeOf(Map m) {
  final e = pickWithKey(m, timeKeys);
  return e == null ? null : toMsWithHint(e.value, e.key);
}

bool isMsgLike(dynamic o) {
  if (o is! Map) return false;
  final hasTime = timeOf(o) != null;
  final hasSender = pick(o, senderKeys) != null;
  final hasText = pick(o, textKeys) != null;
  final hasMedia =
      mediaKeys.any((k) => (o[k] as List?)?.isNotEmpty ?? false) ||
      o['sticker'] != null ||
      o['share'] != null ||
      o['reactions'] is List;
  return hasTime && (hasSender || hasText || hasMedia);
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

/// IDs are hex-ish or contain digits; "ok", "yes" and emoji are quoted text.
bool _looksLikeReplyId(String s) {
  if (s.length < 8 || s.length > 80) return false;
  if (RegExp(r'^[0-9a-fA-F-]{8,}$').hasMatch(s)) return true;
  return s.contains(RegExp(r'\d')) && RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(s);
}

/// Resolve a reply from a nested object or a bare original message ID.
Reply? parseReply(Map m) {
  final ridEntry = pickWithKey(m, replyIdKeys);
  final rvEntry = pickWithKey(m, replyKeys);
  final rid = ridEntry?.value;
  final rv = rvEntry?.value;
  if (rv == null && rid == null) return null;
  if (rv is bool || rv is List) {
    // Some exports mark the reply with a flag/list but keep the ID elsewhere.
    if (rid != null) return Reply(id: '$rid');
    return null;
  }
  if (rv is Map) {
    final tv = pick(rv, textKeys);
    return Reply(
      id: '${pick(rv, msgIdKeys) ?? rid ?? ''}',
      sender: nameOf(pick(rv, ['senderOriginal', ...senderKeys])),
      text: tv == null ? '' : fixEnc(tv is String ? tv : jsonEncode(tv)),
      t: timeOf(rv),
    );
  }
  if (rid != null) return Reply(id: '$rid');
  final s = '$rv';
  // Only *_id fields are certainly IDs. A bare `reply` value may be quoted
  // text such as "ok" or an emoji, so use the shape of the value instead.
  if (ridEntry != null || _looksLikeReplyId(s)) return Reply(id: s);
  return Reply(text: fixEnc(s));
}

Msg normMsg(Map m, {bool keepRaw = true}) {
  // Export-time aliases are written alongside the original identity; prefer
  // the original so re-importing our own export cannot rename people.
  final sender = nameOf(pick(m, ['senderOriginal', ...senderKeys]));
  final t = timeOf(m);
  final tv = pick(m, textKeys);
  final text = tv == null ? '' : fixEnc(tv is String ? tv : jsonEncode(tv));

  final media = <Media>[];
  for (final k in mediaKeys) {
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
  if (st is Map) {
    media.add(Media('sticker', '${st['uri'] ?? ''}'));
  } else if (st is String && st.isNotEmpty) {
    media.add(Media('sticker', st));
  }

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
            nameOf(pick(r, ['actorOriginal', 'actor', 'user', 'name'])),
          ),
        );
      }
    }
  }

  final sv = m['share'];
  final share = sv is Map
      ? '${sv['link'] ?? sv['url'] ?? ''}'
      : sv == null
      ? ''
      : fixEnc('$sv');

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
    // Dropping raw maps saves large amounts of RAM; details/raw export then omit them.
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
    final pv = meta['participantsOriginal'] ?? meta['participants'];
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

/// Return both indexes so a folder scan runs once through the isolate.
typedef MediaDirIndex = ({
  Map<String, String> files,
  Map<String, String> paths,
});

Future<MediaDirIndex> scanInBackground(String dir) =>
    Isolate.run(() => scanDirIndex(dir));

/// Read and parse one JSON file. Runs off the UI thread.
List<ParsedThread> parseFile(String path, {bool keepRaw = true}) {
  final text = File(path).readAsStringSync();
  final json = jsonDecode(text);
  return parseExport(json, path.split(pathSep).last, keepRaw: keepRaw);
}

// ---- Persistent parse cache ----
// Normalized JSON decodes faster than the original export plus field detection.
// Source size and modified time are part of the key, so edits invalidate it.

/// Layout of the cached JSON itself. Bump when the encoder/decoder changes.
const cacheFormatVersion = 1;

/// Bump when field detection, replies or normalization change.
const parserVersion = 2;

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

/// Stream cache writes so the isolate never holds a second full copy.
void _writeCacheFile(File file, List<ParsedThread> threads, bool keepRaw) {
  final raf = file.openSync(mode: FileMode.write);
  try {
    raf.writeStringSync(
      '{"format":$cacheFormatVersion,"parser":$parserVersion,"threads":[',
    );
    for (var ti = 0; ti < threads.length; ti++) {
      final t = threads[ti];
      if (ti > 0) raf.writeStringSync(',');
      raf.writeStringSync(
        '{"k":${jsonEncode(t.key)},"n":${jsonEncode(t.title)},'
        '"p":${jsonEncode(t.participants)},"m":[',
      );
      for (var mi = 0; mi < t.messages.length; mi++) {
        if (mi > 0) raf.writeStringSync(',');
        raf.writeStringSync(jsonEncode(_encodeMsg(t.messages[mi], keepRaw)));
      }
      raf.writeStringSync(']}');
    }
    raf.writeStringSync(']}');
  } finally {
    raf.closeSync();
  }
}

List<ParsedThread> _decodeThreads(Object? value) {
  final root = value as Map?;
  if (root == null ||
      root['format'] != cacheFormatVersion ||
      root['parser'] != parserVersion ||
      root['threads'] is! List) {
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

/// Prune stale/interrupted caches by reading only their short headers.
void pruneParseCache(String cacheDir) {
  final dir = Directory(cacheDir);
  if (!dir.existsSync()) return;
  for (final e in dir.listSync()) {
    if (e is! File) continue;
    final name = e.path.split(pathSep).last;
    try {
      if (name.endsWith('.tmp')) {
        e.deleteSync();
        continue;
      }
      if (!name.endsWith('.json')) continue;
      final raf = e.openSync();
      late final String head;
      try {
        head = utf8.decode(raf.readSync(128));
      } finally {
        raf.closeSync();
      }
      if (!head.contains('"format":$cacheFormatVersion') ||
          !head.contains('"parser":$parserVersion')) {
        e.deleteSync();
      }
    } catch (_) {
      // Unreadable or raced files are cache-only; drop them on the next pass.
      try {
        e.deleteSync();
      } catch (_) {}
    }
  }
}

/// Content fingerprint for caches. Size and mtime alone miss same-length edits
/// made by a re-export, and a head/tail sample misses edits in the middle.
String quickFileFingerprint(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString();

List<ParsedThread> parseFileCached(
  String path, {
  String? cacheDir,
  bool keepRaw = true,
  bool useCache = true,
}) {
  if (!useCache || cacheDir == null) return parseFile(path, keepRaw: keepRaw);

  final sig =
      '$cacheFormatVersion|$parserVersion|$path|${quickFileFingerprint(path)}|${keepRaw ? 1 : 0}';
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
    _writeCacheFile(tmp, threads, keepRaw);
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(file.path);
  } catch (_) {
    // Caching is an optimization; never fail to open an export because of it.
  }
  return threads;
}

/// Basename index kept for callers that do not need relative paths.
Map<String, String> scanDir(String dir) => scanDirIndex(dir).files;

/// Lowercase basename and relative-path indexes for a media folder.
/// Relative paths keep same-named files in different folders distinct.
MediaDirIndex scanDirIndex(String dir) {
  final files = <String, String>{};
  final paths = <String, String>{};
  final root = dir.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
  try {
    for (final e in Directory(
      dir,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = e.path.split(pathSep).last.toLowerCase();
      // Interrupted SAF copies leave .part files behind; they are not media.
      if (name.endsWith('.json') ||
          name.endsWith('.part') ||
          name.endsWith('.tmp')) {
        continue;
      }
      // Case-only collisions must not depend on directory iteration order.
      final prev = files[name];
      if (prev == null || e.path.compareTo(prev) < 0) files[name] = e.path;

      final normalized = e.path.replaceAll('\\', '/');
      final relative = normalized.startsWith('$root/')
          ? normalized.substring(root.length + 1)
          : name;
      final key = relative.toLowerCase();
      final prevPath = paths[key];
      if (prevPath == null || e.path.compareTo(prevPath) < 0) {
        paths[key] = e.path;
      }
    }
  } catch (_) {
    // Keep whatever was found before an unreadable sub-folder.
  }
  return (files: files, paths: paths);
}
