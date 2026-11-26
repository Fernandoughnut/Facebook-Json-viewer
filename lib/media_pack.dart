// Build a ZIP containing only the media a conversation actually references.
//
// The bytes are copied as-is: Facebook/Messenger exports are already encoded,
// and re-encoding them here would only make them worse.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'android_folder.dart';
import 'exporter.dart';
import 'models.dart';
import 'store.dart';
import 'util.dart';

/// One physical file that will be placed in the archive.
class MediaPackFile {
  final String path;
  final String name;

  const MediaPackFile(this.path, this.name);
}

/// One media reference from the conversation, mapped to its packed file.
class MediaPackReference {
  final int messageIndex;
  final String sender;
  final int? timestamp;
  final String kind;
  final String uri;
  final String originalName;
  final String packedAs;

  const MediaPackReference({
    required this.messageIndex,
    required this.sender,
    required this.timestamp,
    required this.kind,
    required this.uri,
    required this.originalName,
    required this.packedAs,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'messageIndex': messageIndex,
    'sender': sender,
    'timestampMs': timestamp,
    'kind': kind,
    'uri': uri,
    'originalName': originalName,
    'packedAs': packedAs,
  };
}

class MediaPackPlan {
  final List<MediaPackFile> files;
  final List<MediaPackReference> references;
  final List<String> missing;

  const MediaPackPlan({
    required this.files,
    required this.references,
    required this.missing,
  });
}

/// Makes a name safe both inside a ZIP and on a normal filesystem. Leading
/// dots are removed so a hash like ".." cannot become a parent path.
String packFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
  final noDots = cleaned.replaceFirst(RegExp(r'^\.+'), '');
  return noDots.isEmpty ? 'media' : noDots;
}

String _withSuffix(String base, int n) {
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return '${base}_$n';
  return '${base.substring(0, dot)}_$n${base.substring(dot)}';
}

/// Plans a conversation-only media pack. Duplicate references to the same
/// physical file are packed once; the manifest still records every reference.
MediaPackPlan planMediaPack(
  Iterable<Msg> messages, {
  required String? Function(String uri) findMedia,
  required String Function(int? timestamp) dateLabel,
  String Function(String sender)? displayName,
}) {
  final list = messages.toList();
  final files = <MediaPackFile>[];
  final references = <MediaPackReference>[];
  final missing = <String>[];
  final nameForPath = <String, String>{};
  final usedNames = <String>{};

  for (var i = 0; i < list.length; i++) {
    final m = list[i];
    for (final x in m.media) {
      if (x.uri.isEmpty) continue;
      final path = findMedia(x.uri);
      final sender = displayName?.call(m.sender) ?? m.sender;
      if (path == null) {
        missing.add(x.name.isEmpty ? x.uri : x.name);
        continue;
      }
      final packed = nameForPath.putIfAbsent(path, () {
        final base =
            '${dateLabel(m.t)}_${packFileName(sender)}_${packFileName(x.name)}';
        var candidate = base;
        var n = 1;
        while (usedNames.contains(candidate)) {
          candidate = _withSuffix(base, n++);
        }
        usedNames.add(candidate);
        files.add(MediaPackFile(path, candidate));
        return candidate;
      });
      references.add(
        MediaPackReference(
          messageIndex: i,
          sender: sender,
          timestamp: m.t,
          kind: x.kind,
          uri: x.uri,
          originalName: x.name,
          packedAs: 'media/$packed',
        ),
      );
    }
  }
  return MediaPackPlan(files: files, references: references, missing: missing);
}

/// A small manifest makes the hashed export names traceable without forcing
/// the conversation JSON to change shape.
Map<String, dynamic> mediaPackManifest({
  required String title,
  String? key,
  required MediaPackPlan plan,
}) => <String, dynamic>{
  'format': 'indexed-media-pack/1',
  'exportedAt': DateTime.now().toIso8601String(),
  'conversation': <String, dynamic>{'title': title, 'key': key},
  'fileCount': plan.files.length,
  'referenceCount': plan.references.length,
  'missingCount': plan.missing.length,
  'files': [for (final f in plan.files) 'media/${f.name}'],
  'references': [for (final r in plan.references) r.toJson()],
  'missing': plan.missing,
};

String _packStamp(DateTime now) =>
    '${now.year}-${two(now.month)}-${two(now.day)}'
    '_${two(now.hour)}${two(now.minute)}${two(now.second)}'
    '_${now.millisecond.toString().padLeft(3, '0')}';

/// Milliseconds matter here: packing twice in the same second must not
/// silently overwrite the first archive.
String mediaPackFileName(String title, DateTime now) =>
    '${safeFileName(title)}_media_${_packStamp(now)}.zip';

String _count(int n, String singular, String plural) =>
    '$n ${n == 1 ? singular : plural}';

/// Runs off the UI thread. Media is STORED, not deflated: photos and videos
/// are already compressed, and streaming avoids loading a whole file at once.
Future<int> buildMediaZip(Map<String, dynamic> args) async {
  final encoder = ZipFileEncoder();
  encoder.create(args['zipPath'] as String);
  var written = 0;
  try {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final entry in (args['documents'] as List).cast<List<String>>()) {
      final bytes = utf8.encode(entry[1]);
      final file = ArchiveFile(entry[0], bytes.length, bytes)
        ..lastModTime = now;
      encoder.addArchiveFile(file);
    }
    for (final raw in (args['files'] as List).cast<List<String>>()) {
      final source = File(raw[0]);
      if (!source.existsSync()) continue;
      encoder.addFile(source, raw[1], ZipFileEncoder.STORE);
      written++;
    }
  } finally {
    await encoder.close();
  }
  return written;
}

/// Build a ZIP for one conversation and save it where the user chooses.
/// Originals are never modified, moved or re-encoded.
Future<void> packConversationMedia(
  BuildContext context,
  Store store,
  Chat chat, {
  Iterable<Msg>? messages,
}) async {
  final msgs = (messages ?? chat.messages).toList();
  final plan = planMediaPack(
    msgs,
    findMedia: (uri) => store.findMedia(uri, chat),
    dateLabel: fmtDate,
    displayName: displayName,
  );

  if (plan.files.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No referenced media files were found to pack.'),
        ),
      );
    }
    return;
  }

  final pack = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Pack conversation media'),
      content: Text(
        '${_count(plan.files.length, 'referenced file', 'referenced files')}, '
        '${_count(plan.references.length, 'reference', 'references')}.'
        '${plan.missing.isEmpty ? '' : ' ${_count(plan.missing.length, 'reference is', 'references are')} missing.'}\n\n'
        'The ZIP will contain the original bytes, a conversation.json export '
        'and a manifest mapping the hashed file names to readable ones.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Choose folder'),
        ),
      ],
    ),
  );
  if (pack != true || !context.mounted) return;

  final folder = Platform.isAndroid
      ? await AndroidMediaExport.pickFolder()
      : await _pickDesktopFolder();
  if (folder == null || !context.mounted) return;

  final fileName = mediaPackFileName(chat.title, DateTime.now());
  final cache = Directory('${store.settings.cacheDir}/exports');
  final zipPath = '${cache.path}${Platform.pathSeparator}$fileName';
  final progress = ValueNotifier<String>('Preparing $fileName…');
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MediaPackProgressDialog(progress: progress),
    ),
  );

  try {
    await cache.create(recursive: true);
    final conversationJson = const JsonEncoder.withIndent('  ').convert(
      chatToJson(
        chat,
        msgs,
        settings: store.settings,
        options: ExportOptions.clean,
      ),
    );
    final manifestJson = const JsonEncoder.withIndent(
      '  ',
    ).convert(mediaPackManifest(title: chat.title, key: chat.key, plan: plan));
    progress.value = 'Packing ${plan.files.length} file(s)…';
    final written = await compute(buildMediaZip, <String, dynamic>{
      'zipPath': zipPath,
      'documents': [
        ['conversation.json', conversationJson],
        ['manifest.json', manifestJson],
      ],
      'files': [
        for (final f in plan.files) [f.path, 'media/${f.name}'],
      ],
    });

    progress.value = 'Saving $fileName…';
    if (Platform.isAndroid) {
      final result = await AndroidMediaExport.writeFile(
        folder,
        zipPath,
        fileName,
        onProgress: (p) {
          final current = p['current'] as int? ?? 0;
          final total = p['total'] as int? ?? 0;
          progress.value = total > 0
              ? 'Saving $fileName… ${(current * 100 / total).round()}%'
              : 'Saving $fileName…';
        },
      );
      final error = result['error'];
      if (error != null) throw Exception(error);
    } else {
      final dest = Directory(folder);
      if (!await dest.exists()) await dest.create(recursive: true);
      await File(zipPath)
          .copy('${dest.path}${Platform.pathSeparator}$fileName');
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved $fileName (${_count(written, 'file', 'files')}'
            '${plan.missing.isEmpty ? '' : ', ${plan.missing.length} missing'})',
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not pack media: $e')));
    }
  } finally {
    try {
      final zip = File(zipPath);
      if (await zip.exists()) await zip.delete();
    } catch (_) {}
    progress.dispose();
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

Future<String?> _pickDesktopFolder() async {
  try {
    final uri = await FilePicker.pickDirectory(
      dialogTitle: 'Choose a folder for the media ZIP',
    );
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
  } catch (_) {}
  return null;
}

class _MediaPackProgressDialog extends StatelessWidget {
  final ValueNotifier<String> progress;
  const _MediaPackProgressDialog({required this.progress});

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    child: AlertDialog(
      title: const Text('Packing conversation media'),
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, text, _) => Text(text),
            ),
          ),
        ],
      ),
    ),
  );
}
