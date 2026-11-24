// Turning loaded conversations into portable files. Nothing is uploaded.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'models.dart';
import 'settings.dart';

enum ExportFormat { json, csv, text }

/// What to include in an export. Raw JSON is off by default: those duplicate
/// fields are what make exports large and hard to read.
class ExportOptions {
  final bool includeRaw;
  final bool includeMedia;
  final bool includeReactions;
  final bool useDisplayNames;

  const ExportOptions({
    this.includeRaw = false,
    this.includeMedia = true,
    this.includeReactions = true,
    this.useDisplayNames = true,
  });

  static const clean = ExportOptions();
  static const withRaw = ExportOptions(includeRaw: true);
}

String _name(AppSettings s, String original, ExportOptions o) =>
    o.useDisplayNames ? s.aliasFor(original) : original;

String? _iso(int? t) =>
    t == null ? null : DateTime.fromMillisecondsSinceEpoch(t).toIso8601String();

Map<String, dynamic> messageToJson(Msg m, AppSettings s, ExportOptions o) {
  String name(String original) => _name(s, original, o);

  final out = <String, dynamic>{
    'sender': name(m.sender),
    'timestampMs': m.t,
    'date': _iso(m.t),
    'type': m.type,
    'text': m.text,
    'unsent': m.unsent,
  };
  if (m.id.isNotEmpty) out['id'] = m.id;
  if (o.useDisplayNames && s.aliasFor(m.sender) != m.sender) {
    out['senderOriginal'] = m.sender;
  }
  if (m.share.isNotEmpty) out['share'] = m.share;
  if (o.includeReactions && m.reactions.isNotEmpty) {
    out['reactions'] = [
      for (final r in m.reactions) {'emoji': r.emoji, 'actor': name(r.actor)},
    ];
  }
  if (o.includeMedia && m.media.isNotEmpty) {
    out['media'] = [
      for (final x in m.media) {'kind': x.kind, 'uri': x.uri, 'name': x.name},
    ];
  }
  final r = m.reply;
  if (r != null) {
    out['reply'] = <String, dynamic>{
      if (r.id.isNotEmpty) 'id': r.id,
      if (r.sender.isNotEmpty) 'sender': name(r.sender),
      if (r.text.isNotEmpty) 'text': r.text,
      if (r.t != null) 'timestampMs': r.t,
    };
  }
  if (o.includeRaw && m.raw.isNotEmpty) out['raw'] = m.raw;
  return out;
}

/// A clean, documented JSON document for one conversation (or a filtered view of it).
Map<String, dynamic> chatToJson(
  Chat chat,
  Iterable<Msg> messages, {
  required AppSettings settings,
  ExportOptions options = ExportOptions.clean,
  String? title,
}) {
  final list = messages.toList();
  final participants =
      chat.participants.map((p) => _name(settings, p, options)).toList()
        ..sort();
  return <String, dynamic>{
    'format': 'messages-viewer/1',
    'exportedAt': DateTime.now().toIso8601String(),
    'title': title ?? chat.title,
    'key': chat.key,
    'participants': participants,
    'messageCount': list.length,
    'messages': [for (final m in list) messageToJson(m, settings, options)],
  };
}

String _csv(String text) {
  final needsQuotes =
      text.contains(',') ||
      text.contains('"') ||
      text.contains('\n') ||
      text.contains('\r');
  final v = text.replaceAll('"', '""');
  return needsQuotes ? '"$v"' : v;
}

String messagesToCsv(
  Iterable<Msg> messages,
  AppSettings s, {
  ExportOptions options = ExportOptions.clean,
}) {
  final b = StringBuffer(
    'timestamp,date,sender,senderOriginal,type,text,media,reactions,share,replyTo\n',
  );
  for (final m in messages) {
    final cells = <String>[
      m.t?.toString() ?? '',
      _iso(m.t) ?? '',
      _name(s, m.sender, options),
      options.useDisplayNames && s.aliasFor(m.sender) != m.sender
          ? m.sender
          : '',
      m.type,
      m.text,
      m.media.map((x) => x.uri).join(' | '),
      m.reactions
          .map((r) => '${r.emoji}:${_name(s, r.actor, options)}')
          .join(' | '),
      m.share,
      m.reply?.id ?? m.reply?.text ?? '',
    ];
    b.writeln(cells.map(_csv).join(','));
  }
  return b.toString();
}

String messagesToText(
  Iterable<Msg> messages,
  AppSettings s, {
  ExportOptions options = ExportOptions.clean,
}) {
  final b = StringBuffer();
  for (final m in messages) {
    final when = m.t == null
        ? 'unknown date'
        : DateTime.fromMillisecondsSinceEpoch(m.t!)
              .toIso8601String()
              .replaceFirst('T', ' ')
              .substring(0, 19);
    b.writeln('[$when] ${_name(s, m.sender, options)}: ${m.text}');
    if (options.includeMedia && m.media.isNotEmpty) {
      b.writeln('    media: ${m.media.map((x) => x.name).join(', ')}');
    }
    if (m.share.isNotEmpty) b.writeln('    link: ${m.share}');
    if (options.includeReactions && m.reactions.isNotEmpty) {
      b.writeln(
        '    reactions: ${m.reactions.map((r) => '${r.emoji} ${_name(s, r.actor, options)}').join(', ')}',
      );
    }
  }
  return b.toString();
}

String encodeExport(
  Chat chat,
  Iterable<Msg> messages, {
  required AppSettings settings,
  required ExportFormat format,
  ExportOptions options = ExportOptions.clean,
}) {
  switch (format) {
    case ExportFormat.json:
      return const JsonEncoder.withIndent('  ').convert(
        chatToJson(chat, messages, settings: settings, options: options),
      );
    case ExportFormat.csv:
      return messagesToCsv(messages, settings, options: options);
    case ExportFormat.text:
      return messagesToText(messages, settings, options: options);
  }
}

String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
  return cleaned.isEmpty ? 'conversation' : cleaned;
}

/// Returns true when a destination was chosen and saved.
Future<bool> saveExport(
  String fileName,
  String content, {
  String mimeType = 'application/json',
}) async {
  try {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: mimeType,
    );
    return uri != null;
  } catch (_) {
    return false;
  }
}
