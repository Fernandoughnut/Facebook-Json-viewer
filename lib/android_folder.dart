// Bridge to the Android Storage Access Framework folder importer.
//
// SAF tree URIs cannot be read with dart:io, so the native side streams files
// into an app-private folder and Dart scans that folder like any other.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

class AndroidFolderPicker {
  static const MethodChannel _channel = MethodChannel(
    'dev.local.indexed/folder',
  );

  /// Opens the Android folder picker. Returns a content:// tree URI, or null
  /// when the user cancels. Unsupported platforms return null without a call.
  static Future<String?> pick() async {
    try {
      return await _channel.invokeMethod<String>('pickFolder');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Copies the picked tree's media files into [destDir]. Progress frames from
  /// Kotlin are forwarded to [onProgress] while the copy is running.
  static Future<Map<String, dynamic>> import(
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
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'importFolder',
        {'uri': uri, 'destDir': destDir, 'importId': importId},
      );
      return result ?? <String, dynamic>{};
    } on PlatformException catch (e) {
      return <String, dynamic>{'error': e.message ?? e.code};
    } on MissingPluginException catch (e) {
      return <String, dynamic>{
        'error': e.message ?? 'Folder importer unavailable',
      };
    } finally {
      _channel.setMethodCallHandler(null);
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

  /// Stable short name for a tree URI, so re-picking the same folder reuses
  /// the already imported files instead of duplicating them.
  static String folderNameFor(String uri) =>
      sha1.convert(utf8.encode(uri)).toString().substring(0, 12);
}
