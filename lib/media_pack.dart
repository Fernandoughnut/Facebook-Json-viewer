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

/// How media is named inside a conversation ZIP.
enum MediaNamingMode {
  /// Keep the exported names and folder structure so the files can be added
  /// back as a media folder and matched to the unchanged conversation JSON.
  originalSorted,

  /// Human-readable `YYYY-MM-DD_Sender_original` names. Pretty to browse, but
  /// the original URIs no longer match unless the manifest is used to restore.
  readableDate,
}

MediaNamingMode mediaNamingFrom(String? value) => switch (value) {
  'readableDate' => MediaNamingMode.readableDate,
  _ => MediaNamingMode.originalSorted,
};

class MediaPackOptions {
  final MediaNamingMode naming;
  final bool keepDuplicateReferences;

  const MediaPackOptions({
    this.naming = MediaNamingMode.originalSorted,
    this.keepDuplicateReferences = false,
  });
}

/// One physical file that will be placed in the archive.
class MediaPackFile {
  final String path;

  /// Archive-relative path, always starting with `media/`.
  final String name;
  final int? timestamp;
  final int order;

  const MediaPackFile(this.path, this.name, {this.timestamp, this.order = 0});
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
  final List<String> unreadable;
  final int duplicateReferences;
  final int emptyReferences;
  final MediaNamingMode naming;
  final bool keepDuplicateReferences;

  const MediaPackPlan({
    required this.files,
    required this.references,
    required this.missing,
    this.unreadable = const <String>[],
    this.duplicateReferences = 0,
    this.emptyReferences = 0,
    this.naming = MediaNamingMode.originalSorted,
    this.keepDuplicateReferences = false,
  });

  MediaPackPlan copyWith({
    List<MediaPackFile>? files,
    List<MediaPackReference>? references,
    List<String>? missing,
    List<String>? unreadable,
    int? duplicateReferences,
    int? emptyReferences,
    MediaNamingMode? naming,
    bool? keepDuplicateReferences,
  }) => MediaPackPlan(
    files: files ?? this.files,
    references: references ?? this.references,
    missing: missing ?? this.missing,
    unreadable: unreadable ?? this.unreadable,
    duplicateReferences: duplicateReferences ?? this.duplicateReferences,
    emptyReferences: emptyReferences ?? this.emptyReferences,
    naming: naming ?? this.naming,
    keepDuplicateReferences:
        keepDuplicateReferences ?? this.keepDuplicateReferences,
  );
}

/// Makes one archive path segment safe on every filesystem.
String packFileName(String name) {
  var cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\r\n]'), '_').trim();
  cleaned = cleaned.replaceFirst(RegExp(r'^\.+'), '');
  cleaned = cleaned.replaceFirst(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty) return 'media';
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
    caseSensitive: false,
  );
  if (reserved.hasMatch(cleaned)) cleaned = '_$cleaned';
  if (cleaned.length > 180) cleaned = cleaned.substring(0, 180);
  return cleaned;
}

/// Preserve the relative path from the JSON where possible. Keeping `media/`
/// intact means an extracted pack can be added straight back as a media folder.
String _archivePathForUri(String uri) {
  var clean = uri.replaceAll('\\', '/');
  final cut = clean.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) clean = clean.substring(0, cut);
  final parts = clean
      .split('/')
      .where((p) => p.isNotEmpty && p != '.' && p != '..')
      .map(packFileName)
      .toList();
  if (parts.isEmpty) return 'media/media';
  if (parts.first.toLowerCase() == 'media') return parts.join('/');
  return 'media/${parts.join('/')}';
}

String _withSuffix(String base, int n) {
  final slash = base.lastIndexOf('/');
  final prefix = slash < 0 ? '' : base.substring(0, slash + 1);
  final name = slash < 0 ? base : base.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  final tagged = dot <= 0
      ? '${name}_$n'
      : '${name.substring(0, dot)}_$n${name.substring(dot)}';
  return '$prefix$tagged';
}

String _allocateName(String base, Set<String> used) {
  var candidate = base;
  var n = 1;
  // ZIP tools on Windows/macOS are case-insensitive too.
  while (!used.add(candidate.toLowerCase())) {
    candidate = _withSuffix(base, n++);
  }
  return candidate;
}

/// Plans a conversation-only media pack. By default each physical file is
/// packed once; [MediaPackOptions.keepDuplicateReferences] can instead keep one
/// entry per reference. Every reference is still recorded in the manifest.
MediaPackPlan planMediaPack(
  Iterable<Msg> messages, {
  required String? Function(String uri) findMedia,
  required String Function(int? timestamp) dateLabel,
  String Function(String sender)? displayName,
  MediaPackOptions options = const MediaPackOptions(),
}) {
  final list = messages.toList();
  final files = <MediaPackFile>[];
  final references = <MediaPackReference>[];
  final missing = <String>[];
  final nameForPath = <String, String>{};
  final usedNames = <String>{};
  var duplicateReferences = 0;
  var emptyReferences = 0;

  for (var i = 0; i < list.length; i++) {
    final m = list[i];
    for (final x in m.media) {
      if (x.uri.trim().isEmpty) {
        emptyReferences++;
        continue;
      }
      final path = findMedia(x.uri);
      final sender = displayName?.call(m.sender) ?? m.sender;
      if (path == null) {
        missing.add(x.name.isEmpty ? x.uri : x.name);
        continue;
      }

      final previous = nameForPath[path];
      if (previous != null && !options.keepDuplicateReferences) {
        duplicateReferences++;
        references.add(
          MediaPackReference(
            messageIndex: i,
            sender: sender,
            timestamp: m.t,
            kind: x.kind,
            uri: x.uri,
            originalName: x.name,
            packedAs: previous,
          ),
        );
        continue;
      }

      final base = options.naming == MediaNamingMode.readableDate
          ? 'media/${dateLabel(m.t)}_${packFileName(sender)}_${packFileName(x.name)}'
          : _archivePathForUri(x.uri);
      final packed = _allocateName(base, usedNames);
      final file = MediaPackFile(
        path,
        packed,
        timestamp: m.t,
        order: files.length,
      );
      files.add(file);
      nameForPath.putIfAbsent(path, () => packed);
      references.add(
        MediaPackReference(
          messageIndex: i,
          sender: sender,
          timestamp: m.t,
          kind: x.kind,
          uri: x.uri,
          originalName: x.name,
          packedAs: packed,
        ),
      );
    }
  }

  // "Sorted" must be explicit: a filtered message list is not necessarily in
  // date order, and ZIP entry order is what users see when they open it.
  files.sort((a, b) {
    final at = a.timestamp ?? 0x7fffffffffffffff;
    final bt = b.timestamp ?? 0x7fffffffffffffff;
    final byDate = at.compareTo(bt);
    return byDate != 0 ? byDate : a.order.compareTo(b.order);
  });

  return MediaPackPlan(
    files: files,
    references: references,
    missing: missing,
    duplicateReferences: duplicateReferences,
    emptyReferences: emptyReferences,
    naming: options.naming,
    keepDuplicateReferences: options.keepDuplicateReferences,
  );
}

/// Drops paths that vanished after the media folder was indexed so the ZIP and
/// its manifest cannot disagree about which files are actually included.
MediaPackPlan pruneUnreadableMediaPack(MediaPackPlan plan) {
  final kept = <MediaPackFile>[];
  final unreadable = <String>[...plan.unreadable];
  final unreadableSet = unreadable.toSet();
  for (final f in plan.files) {
    if (File(f.path).existsSync()) {
      kept.add(f);
    } else if (unreadableSet.add(f.name)) {
      unreadable.add(f.name);
    }
  }
  if (unreadable.length == plan.unreadable.length) return plan;

  final missing = <String>[...plan.missing];
  final missingSet = missing.toSet();
  final packed = kept.map((f) => f.name).toSet();
  final keptRefs = <MediaPackReference>[];
  for (final ref in plan.references) {
    if (!packed.contains(ref.packedAs)) {
      final name = ref.originalName.isEmpty ? ref.uri : ref.originalName;
      if (name.isNotEmpty && missingSet.add(name)) missing.add(name);
      continue;
    }
    keptRefs.add(ref);
  }
  final seenPacked = <String>{};
  var duplicates = 0;
  var empty = 0;
  for (final ref in keptRefs) {
    if (!seenPacked.add(ref.packedAs)) duplicates++;
    if (ref.uri.trim().isEmpty) empty++;
  }
  return plan.copyWith(
    files: kept,
    references: keptRefs,
    missing: missing,
    unreadable: unreadable,
    duplicateReferences: duplicates,
    emptyReferences: empty,
  );
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
  'naming': plan.naming.name,
  'order': 'chronological',
  'fileCount': plan.files.length,
  'referenceCount': plan.references.length,
  'duplicateReferences': plan.duplicateReferences,
  'emptyReferences': plan.emptyReferences,
  'missingCount': plan.missing.length,
  'unreadableAtPackTime': plan.unreadable,
  'files': [for (final f in plan.files) f.name],
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
Future<Map<String, dynamic>> buildMediaZip(Map<String, dynamic> args) async {
  final encoder = ZipFileEncoder();
  encoder.create(args['zipPath'] as String);
  var written = 0;
  final skipped = <String>[];
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
      if (!source.existsSync()) {
        skipped.add(raw[1]);
        continue;
      }
      encoder.addFile(source, raw[1], ZipFileEncoder.STORE);
      written++;
    }
  } finally {
    await encoder.close();
  }
  return <String, dynamic>{'written': written, 'skipped': skipped};
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
  final mediaLookup = <String, String?>{};
  String? findCached(String uri) =>
      mediaLookup.putIfAbsent(uri, () => store.findMedia(uri, chat));

  MediaPackPlan planFor(MediaPackOptions options) => planMediaPack(
    msgs,
    findMedia: findCached,
    dateLabel: fmtDate,
    displayName: displayName,
    options: options,
  );

  var chosen = MediaPackOptions(
    naming: mediaNamingFrom(store.settings.mediaPackNaming),
  );
  MediaPackPlan preview = planFor(chosen);
  final options = await showDialog<MediaPackOptions?>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        preview = planFor(chosen);
        final missingNote = preview.missing.isEmpty
            ? ''
            : ' ${_count(preview.missing.length, 'reference is', 'references are')} missing.';
        final emptyNote = preview.emptyReferences == 0
            ? ''
            : ' ${_count(preview.emptyReferences, 'empty reference', 'empty references')} skipped.';
        final unreadableNote = preview.unreadable.isEmpty
            ? ''
            : ' ${_count(preview.unreadable.length, 'file', 'files')} vanished after indexing.';
        final duplicateNote = preview.duplicateReferences == 0
            ? ''
            : chosen.keepDuplicateReferences
            ? ' ${_count(preview.duplicateReferences, 'repeated reference', 'repeated references')} kept as separate copies.'
            : ' ${_count(preview.duplicateReferences, 'repeated reference', 'repeated references')} point to files already packed.';
        return AlertDialog(
          title: const Text('Pack conversation media'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_count(preview.references.length, 'reference', 'references')} → '
                  '${_count(preview.files.length, 'file', 'files')}.'
                  '$duplicateNote$missingNote$emptyNote$unreadableNote',
                ),
                const SizedBox(height: 12),
                const Text('Media names'),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    chosen.naming == MediaNamingMode.originalSorted
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  onTap: () => setState(
                    () => chosen = MediaPackOptions(
                      naming: MediaNamingMode.originalSorted,
                      keepDuplicateReferences: chosen.keepDuplicateReferences,
                    ),
                  ),
                  title: const Text('Original names, sorted by date'),
                  subtitle: const Text(
                    'media/<original path>; can be added back as a media folder.',
                  ),
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    chosen.naming == MediaNamingMode.readableDate
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  onTap: () => setState(
                    () => chosen = MediaPackOptions(
                      naming: MediaNamingMode.readableDate,
                      keepDuplicateReferences: chosen.keepDuplicateReferences,
                    ),
                  ),
                  title: const Text('Date + sender names'),
                  subtitle: const Text(
                    'YYYY-MM-DD_Sender_original; nicer to browse, not re-importable.',
                  ),
                ),
                CheckboxListTile(
                  dense: true,
                  value: chosen.keepDuplicateReferences,
                  onChanged: (v) => setState(
                    () => chosen = MediaPackOptions(
                      naming: chosen.naming,
                      keepDuplicateReferences: v ?? false,
                    ),
                  ),
                  title: const Text('Pack repeated references separately'),
                  subtitle: const Text(
                    'One ZIP entry per reference, even when it is the same file.',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The ZIP stores the original bytes, conversation.json and a '
                  'manifest mapping every hashed URI to its packed file.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, chosen),
              child: const Text('Choose folder'),
            ),
          ],
        );
      },
    ),
  );
  if (options == null || !context.mounted) return;

  store.settings.mediaPackNaming = options.naming.name;
  store.settings.save();
  final plan = pruneUnreadableMediaPack(preview);
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
    final result = await compute(buildMediaZip, <String, dynamic>{
      'zipPath': zipPath,
      'documents': [
        ['conversation.json', conversationJson],
        ['manifest.json', manifestJson],
      ],
      'files': [
        for (final f in plan.files) [f.path, f.name],
      ],
    });
    final written = result['written'] as int? ?? 0;
    final skipped = (result['skipped'] as List?)?.cast<String>() ?? const [];

    progress.value = 'Saving $fileName…';
    if (Platform.isAndroid) {
      final save = await AndroidMediaExport.writeFile(
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
      final error = save['error'];
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
            '${plan.missing.isEmpty ? '' : ', ${plan.missing.length} missing'}'
            '${skipped.isEmpty ? '' : ', ${skipped.length} vanished'})',
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
