// The parse cache must survive a round trip and invalidate when the source changes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/parser.dart';
import 'package:fb_viewer/settings.dart';

void main() {
  const fixture = 'test/fixtures/test_message.json';

  test('cache round-trips normalized messages', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_cache_test_');
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

  test('cache rejects results written by an older parser', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_cache_test_');
    addTearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final source = File('${dir.path}${Platform.pathSeparator}export.json');
    File(fixture).copySync(source.path);
    final cache = '${dir.path}/cache';

    parseFileCached(source.path, cacheDir: cache);
    final cacheFile = Directory(cache).listSync().whereType<File>().single;
    final root = jsonDecode(cacheFile.readAsStringSync()) as Map;
    expect(root['format'], cacheFormatVersion);
    expect(root['parser'], parserVersion);

    // Simulate a cache written before a parser-behaviour change.
    root.remove('parser');
    cacheFile.writeAsStringSync(jsonEncode(root));

    final rebuilt = parseFileCached(source.path, cacheDir: cache);
    expect(rebuilt.single.messages.length, 74);
  });

  test('pruning removes stale versions and interrupted writes', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_cache_test_');
    addTearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final cache = '${dir.path}/cache';
    Directory(cache).createSync(recursive: true);

    final stale = File('$cache/stale.json')
      ..writeAsStringSync('{"format":0,"parser":0,"threads":[]}');
    final partial = File('$cache/orphan.tmp')..writeAsStringSync('partial');
    final valid = File('$cache/valid.json')
      ..writeAsStringSync(
        '{"format":$cacheFormatVersion,"parser":$parserVersion,"threads":[]}',
      );

    pruneParseCache(cache);

    expect(stale.existsSync(), isFalse);
    expect(partial.existsSync(), isFalse);
    expect(valid.existsSync(), isTrue);
  });

  test('cache invalidates when the source file changes', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_cache_test_');
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
    final dir = await Directory.systemTemp.createTemp('indexed_cache_test_');
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
    final dir = await Directory.systemTemp.createTemp('indexed_cache_test_');
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
