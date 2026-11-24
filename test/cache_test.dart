// The parse cache must survive a round trip and invalidate when the source changes.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/parser.dart';
import 'package:fb_viewer/settings.dart';

void main() {
  const fixture = 'test/fixtures/test_message.json';

  test('cache round-trips normalized messages', () async {
    final dir = await Directory.systemTemp.createTemp('fb_viewer_cache_test_');
    addTearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final source = File('${dir.path}${Platform.pathSeparator}export.json');
    File(fixture).copySync(source.path);

    final first = parseFileCached(source.path, cacheDir: '${dir.path}/cache');
    expect(first.single.messages.length, 74);
    final fromCache = parseFileCached(
      source.path,
      cacheDir: '${dir.path}/cache',
    );
    expect(fromCache.single.messages.length, first.single.messages.length);
    expect(
      fromCache.single.messages.first.text,
      first.single.messages.first.text,
    );
    expect(fromCache.single.messages.last.reactions.last.emoji, '❤');
  });

  test('cache invalidates when the source file changes', () async {
    final dir = await Directory.systemTemp.createTemp('fb_viewer_cache_test_');
    addTearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final source = File('${dir.path}${Platform.pathSeparator}export.json');
    File(fixture).copySync(source.path);
    final cache = '${dir.path}/cache';

    final before = parseFileCached(source.path, cacheDir: cache);
    expect(before.single.messages.first.text, 'Boii');

    final raw = source.readAsStringSync().replaceFirst('"Boii"', '"Changed"');
    source.writeAsStringSync(raw);
    await source.setLastModified(
      DateTime.now().add(const Duration(seconds: 2)),
    );

    final after = parseFileCached(source.path, cacheDir: cache);
    expect(after.single.messages.first.text, 'Changed');
  });

  test('keepRaw: false drops original maps but keeps the message', () async {
    final dir = await Directory.systemTemp.createTemp('fb_viewer_cache_test_');
    addTearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final source = File('${dir.path}${Platform.pathSeparator}export.json');
    File(fixture).copySync(source.path);

    final msgs = parseFileCached(
      source.path,
      cacheDir: '${dir.path}/cache',
      keepRaw: false,
    ).single.messages;
    expect(msgs.length, 74);
    expect(msgs.every((m) => m.raw.isEmpty), isTrue);
    expect(msgs.first.text, 'Boii');
  });

  test('clearParseCache removes stale temporary files', () async {
    final dir = await Directory.systemTemp.createTemp('fb_viewer_cache_test_');
    addTearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);

    final cache = Directory(settings.cacheDir)..createSync(recursive: true);
    final stale = File('${cache.path}/old.json.123.tmp')
      ..writeAsStringSync('half written');
    expect(stale.existsSync(), isTrue);

    settings.clearParseCache();
    expect(stale.existsSync(), isFalse);
  });
}
