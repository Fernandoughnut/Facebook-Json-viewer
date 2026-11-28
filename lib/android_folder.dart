// Bridge to the Android SAF folder importer.
// SAF trees are copied into app-private storage before Dart scans them.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Routes progress frames to the import that produced them.
///
/// Media and JSON imports can overlap, so each import gets its own id and the
/// channel keeps one handler for the lifetime of the app.
class ImportProgressRouter {
  final Map<String, void Function(Map<String, dynamic>)> _listeners =
      <String, void Function(Map<String, dynamic>)>{};

  int get listenerCount => _listeners.length;

  void register(String id, void Function(Map<String, dynamic>) listener) =>
      _listeners[id] = listener;

  void unregister(String id) => _listeners.remove(id);

  void dispatch(String method, Object? arguments) {
    if (method != 'importProgress' || arguments is! Map) return;
    final id = arguments['importId'] as String?;
    if (id == null) return;
    _listeners[id]?.call(Map<String, dynamic>.from(arguments));
  }
}

/// Only a failed first import may clean up its new folder. Re-picking the same
/// tree reuses a hashed folder that may already hold a complete import.
bool shouldDiscardImportDir({required bool existedBefore}) => !existedBefore;

class AndroidFolderPicker {
  static const MethodChannel _channel = MethodChannel(
    'dev.local.indexed/folder',
  );
  static final ImportProgressRouter _progress = ImportProgressRouter();
  static bool _listening = false;

  /// Open the folder picker; returns a tree URI or null on cancel/unsupported.
  static Future<String?> pick() async {
    try {
      return await _channel.invokeMethod<String>('pickFolder');
    } catch (_) {
      return null;
    }
  }

  /// Copy media files into [destDir], forwarding progress frames.
  static Future<Map<String, dynamic>> import(
    String uri,
    String destDir, {
    void Function(Map<String, dynamic>)? onProgress,
    void Function(String)? onStarted,
  }) => _copyTree(
    'importFolder',
    uri,
    destDir,
    onProgress: onProgress,
    onStarted: onStarted,
  );

  /// Copy JSON files into [destDir] and return their paths.
  static Future<Map<String, dynamic>> importJson(
    String uri,
    String destDir, {
    void Function(Map<String, dynamic>)? onProgress,
  }) => _copyTree('importJsonFolder', uri, destDir, onProgress: onProgress);

  static void _ensureListener() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(
      (call) async => _progress.dispatch(call.method, call.arguments),
    );
  }

  static Future<Map<String, dynamic>> _copyTree(
    String method,
    String uri,
    String destDir, {
    void Function(Map<String, dynamic>)? onProgress,
    void Function(String)? onStarted,
  }) async {
    final importId = DateTime.now().microsecondsSinceEpoch.toString();
    _ensureListener();
    if (onProgress != null) _progress.register(importId, onProgress);
    onStarted?.call(importId);
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(method, {
        'uri': uri,
        'destDir': destDir,
        'importId': importId,
      });
      return result ?? <String, dynamic>{};
    } on PlatformException catch (e) {
      return <String, dynamic>{'error': e.message ?? e.code};
    } on MissingPluginException catch (e) {
      return <String, dynamic>{
        'error': e.message ?? 'Folder importer unavailable',
      };
    } catch (e) {
      return <String, dynamic>{'error': e.toString()};
    } finally {
      _progress.unregister(importId);
    }
  }

  /// Open web links in the browser; local files stay app-private on Android.
  static Future<bool> openLink(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openLink', {'url': url}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Ask one native importer to stop after the current file. [importId] keeps
  /// a late Cancel from stopping a different import.
  static Future<void> cancelImport(String importId) async {
    try {
      await _channel.invokeMethod<void>('cancelImport', {'importId': importId});
    } catch (_) {
      // Already cancelled or not on Android.
    }
  }

  /// Stable short tree-URI name so re-picking a folder does not duplicate files.
  static String folderNameFor(String uri) {
    // Normalize percent-escape case without decoding separators.
    final canonical = uri.replaceAllMapped(
      RegExp(r'%[0-9a-fA-F]{2}'),
      (m) => m.group(0)!.toUpperCase(),
    );
    return sha1.convert(utf8.encode(canonical)).toString().substring(0, 12);
  }
}

/// Stream a ZIP straight to SAF storage instead of over the method channel.
class AndroidMediaExport {
  static const MethodChannel _channel = MethodChannel(
    'dev.local.indexed/export',
  );
  static final Map<String, void Function(Map<String, dynamic>)> _listeners =
      <String, void Function(Map<String, dynamic>)>{};
  static bool _listening = false;

  /// Keep one export channel handler so later exports still receive progress.
  static void _ensureListener() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'exportProgress') return;
      final args = call.arguments;
      if (args is! Map) return;
      final id = args['exportId'] as String?;
      if (id == null) return;
      _listeners[id]?.call(Map<String, dynamic>.from(args));
    });
  }

  /// Picks a folder with write permission. Returns a content:// tree URI.
  static Future<String?> pickFolder() async {
    try {
      return await _channel.invokeMethod<String>('pickExportFolder');
    } catch (_) {
      return null;
    }
  }

  /// Streams [sourcePath] into [folderUri] under [fileName].
  static Future<Map<String, dynamic>> writeFile(
    String folderUri,
    String sourcePath,
    String fileName, {
    void Function(Map<String, dynamic>)? onProgress,
  }) async {
    final exportId = DateTime.now().microsecondsSinceEpoch.toString();
    _ensureListener();
    if (onProgress != null) _listeners[exportId] = onProgress;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'writeFileToFolder',
        {
          'uri': folderUri,
          'sourcePath': sourcePath,
          'fileName': fileName,
          'exportId': exportId,
        },
      );
      return result ?? <String, dynamic>{};
    } on PlatformException catch (e) {
      return <String, dynamic>{'error': e.message ?? e.code};
    } on MissingPluginException catch (e) {
      return <String, dynamic>{
        'error': e.message ?? 'Media export is unavailable',
      };
    } catch (e) {
      return <String, dynamic>{'error': e.toString()};
    } finally {
      _listeners.remove(exportId);
    }
  }

  /// Copy chosen local files into a writable SAF tree under new names.
  /// Each job is [sourcePath, destinationName].
  static Future<Map<String, dynamic>> copyFiles(
    String folderUri,
    List<List<String>> jobs,
  ) async {
    _ensureListener();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'copyFilesToFolder',
        {'uri': folderUri, 'jobs': jobs},
      );
      return result ?? <String, dynamic>{};
    } on PlatformException catch (e) {
      return <String, dynamic>{'error': e.message ?? e.code};
    } on MissingPluginException catch (e) {
      return <String, dynamic>{
        'error': e.message ?? 'Media export is unavailable',
      };
    } catch (e) {
      return <String, dynamic>{'error': e.toString()};
    }
  }
}
