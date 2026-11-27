// Bridge to the Android SAF folder importer.
// SAF trees are copied into app-private storage before Dart scans them.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

class AndroidFolderPicker {
  static const MethodChannel _channel = MethodChannel(
    'dev.local.indexed/folder',
  );

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
  }) => _copyTree('importFolder', uri, destDir, onProgress: onProgress);

  /// Copy JSON files into [destDir] and return their paths.
  static Future<Map<String, dynamic>> importJson(
    String uri,
    String destDir, {
    void Function(Map<String, dynamic>)? onProgress,
  }) => _copyTree('importJsonFolder', uri, destDir, onProgress: onProgress);

  static Future<Map<String, dynamic>> _copyTree(
    String method,
    String uri,
    String destDir, {
    void Function(Map<String, dynamic>)? onProgress,
  }) async {
    final importId = DateTime.now().microsecondsSinceEpoch.toString();
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'importProgress') return;
      final args = call.arguments;
      if (args is Map && args['importId'] == importId) {
        onProgress?.call(Map<String, dynamic>.from(args));
      }
    });
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
      _channel.setMethodCallHandler(null);
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

  /// Ask the native importer to stop after the current file.
  static Future<void> cancelImport() async {
    try {
      await _channel.invokeMethod<void>('cancelImport');
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
}
