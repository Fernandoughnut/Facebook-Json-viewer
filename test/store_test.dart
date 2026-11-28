// Store-level state that must not leak between conversations.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/models.dart';
import 'package:fb_viewer/parser.dart';
import 'package:fb_viewer/settings.dart';
import 'package:fb_viewer/store.dart';

void main() {
  test(
    'removing a chat also clears its entries from the reply index',
    () async {
      final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final settings = AppSettings(configDir: dir.path);
      addTearDown(settings.dispose);
      await settings.load();
      final store = Store(settings);

      final chat = Chat('chat-a', 'Chat A');
      final target = _msg('m1', 'Ana', 1000);
      final reply = _msg('m2', 'Ben', 2000, reply: const Reply(id: 'm1'));
      chat.messages.addAll([target, reply]);
      store.chats[chat.key] = chat;

      expect(store.resolveReplies(chat), 1);
      expect(store.replyCount(target), 1);

      store.removeChat(chat);

      expect(store.chats, isEmpty);
      expect(store.replyCount(target), 0);
      expect(store.repliesTo(target), isEmpty);
    },
  );

  test('sortedChats is cached until the data revision changes', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_sort_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final older = Chat('older', 'Older');
    older.messages.add(_msg('m1', 'Ana', 1000));
    final newer = Chat('newer', 'Newer');
    newer.messages.add(_msg('m2', 'Ben', 2000));
    store.chats
      ..[older.key] = older
      ..[newer.key] = newer;

    final first = store.sortedChats;
    expect(first.map((c) => c.key), ['newer', 'older']);
    expect(identical(first, store.sortedChats), isTrue);

    store.dataRevision++;
    expect(identical(first, store.sortedChats), isFalse);
    expect(store.sortedChats.map((c) => c.key), ['newer', 'older']);
  });

  test('media stats are cached until the media folders change', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final chat = Chat('chat-b', 'Chat B');
    chat.messages.add(
      _msg('m3', 'Ana', 3000, media: const [Media('photos', 'photos/a.jpg')]),
    );
    store.chats[chat.key] = chat;

    final before = store.statsFor(chat);
    expect(before.total, 1);
    expect(before.missing, 1);
    expect(identical(before, store.statsFor(chat)), isTrue);

    final folder = Directory('${dir.path}/photos')..createSync(recursive: true);
    File('${folder.path}/a.jpg').writeAsStringSync('image');
    store.sharedDirs.add(
      MediaDir(folder.path, {'a.jpg': '${folder.path}/a.jpg'}),
    );
    store.mediaVersion++;

    final after = store.statsFor(chat);
    expect(after.fromShared, 1);
    expect(identical(after, before), isFalse);
  });

  test('missing media export is not truncated by the dialog sample', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final chat = Chat('chat-c', 'Chat C');
    for (var i = 0; i < 35; i++) {
      chat.messages.add(
        _msg('m$i', 'Ana', i + 1, media: [Media('photos', 'photos/$i.jpg')]),
      );
    }
    store.chats[chat.key] = chat;

    expect(store.statsFor(chat).missingSample, hasLength(30));
    expect(store.missingMediaNames(chat), hasLength(35));
  });

  test('removing every chat from a file stops restoring that file', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final json = File('${dir.path}/messages.json')
      ..writeAsStringSync(
        File('test/fixtures/test_message.json').readAsStringSync(),
      );
    await store.addJsonFiles([json.path], remember: true);
    expect(store.chats, isNotEmpty);
    expect(settings.jsonPaths, contains(json.path));

    for (final chat in store.chats.values.toList()) {
      store.removeChat(chat);
    }
    expect(settings.jsonPaths, isNot(contains(json.path)));
  });

  test(
    'overlapping imports dedupe after the seen index was compacted',
    () async {
      final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final settings = AppSettings(configDir: dir.path);
      addTearDown(settings.dispose);
      await settings.load();
      final store = Store(settings);

      final source = File('test/fixtures/test_message.json').readAsStringSync();
      final first = File('${dir.path}/first.json')..writeAsStringSync(source);
      final second = File('${dir.path}/second.json')..writeAsStringSync(source);

      await store.addJsonFiles([first.path]);
      final initial = store.chats.values.fold<int>(
        0,
        (n, c) => n + c.messages.length,
      );
      await store.addJsonFiles([second.path]);
      final after = store.chats.values.fold<int>(
        0,
        (n, c) => n + c.messages.length,
      );

      expect(initial, greaterThan(0));
      expect(after, initial);
    },
  );

  test('global search returns nothing for an empty query', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final chat = Chat('chat-d', 'Chat D');
    chat.messages.add(_msg('m1', 'Ana', 1000, text: 'hello'));
    store.chats[chat.key] = chat;

    final result = store.searchAll('');
    expect(result.hits, isEmpty);
    expect(result.truncated, isFalse);
  });

  test('global search stops at the limit and reports truncation', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final chat = Chat('chat-e', 'Chat E');
    for (var i = 0; i < 12; i++) {
      chat.messages.add(_msg('m$i', 'Ana', i + 1, text: 'needle'));
    }
    store.chats[chat.key] = chat;

    final capped = store.searchAll('needle', limit: 10);
    expect(capped.hits, hasLength(10));
    expect(capped.truncated, isTrue);

    final exact = store.searchAll('needle', limit: 12);
    expect(exact.hits, hasLength(12));
    expect(exact.truncated, isFalse);
  });

  test('bookmark toggles do not invalidate heavy insights data', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_store_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);

    final chat = Chat('chat-f', 'Chat F');
    final msg = _msg('m1', 'Ana', 1000);
    chat.messages.add(msg);
    store.chats[chat.key] = chat;

    final dataRevision = store.dataRevision;
    final bookmarkRevision = store.bookmarkRevision;

    store.toggleBookmark(chat, msg);
    expect(store.bookmarkRevision, bookmarkRevision + 1);
    expect(store.dataRevision, dataRevision);
    expect(store.bookmarked(), hasLength(1));

    store.toggleBookmark(chat, msg);
    expect(store.bookmarkRevision, bookmarkRevision + 2);
    expect(store.dataRevision, dataRevision);
    expect(store.bookmarked(), isEmpty);
  });

  test('explicitly re-adding a JSON revives a removed conversation', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_revive_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);
    addTearDown(store.dispose);

    final json = File('${dir.path}/messages.json')
      ..writeAsStringSync(
        File('test/fixtures/test_message.json').readAsStringSync(),
      );
    await store.addJsonFiles([json.path]);
    final chat = store.chats.values.single;
    final key = chat.key;
    final count = chat.messages.length;
    expect(count, greaterThan(0));

    store.removeChat(chat);
    expect(store.chats, isEmpty);
    expect(settings.removedChats, contains(key));
    expect(settings.jsonPaths, isNot(contains(json.path)));

    await store.addJsonFiles([json.path], reviveRemoved: true);
    expect(store.chats[key], isNotNull);
    expect(store.chats[key]!.messages, hasLength(count));
    expect(settings.removedChats, isNot(contains(key)));
    expect(settings.jsonPaths, contains(json.path));
    expect(store.status, isNot(contains('Skipped')));

    await settings.flush();
    final reloaded = AppSettings(configDir: dir.path);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.removedChats, isNot(contains(key)));
    expect(reloaded.jsonPaths, contains(json.path));
  });

  test('automatic restore still skips removed conversations', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_revive_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);
    addTearDown(store.dispose);

    final json = File('${dir.path}/messages.json')
      ..writeAsStringSync(
        File('test/fixtures/test_message.json').readAsStringSync(),
      );
    await store.addJsonFiles([json.path]);
    final chat = store.chats.values.single;
    final key = chat.key;
    store.removeChat(chat);

    // Simulate an older state file that still remembers the JSON path.
    settings.jsonPaths.add(json.path);
    await store.restoreSession();

    expect(store.chats, isEmpty);
    expect(settings.removedChats, contains(key));
    expect(settings.jsonPaths, isNot(contains(json.path)));
  });

  test(
    'explicit re-add revives only removed threads in a shared file',
    () async {
      for (final dedupe in [true, false]) {
        final dir = await Directory.systemTemp.createTemp(
          'indexed_multi_test_',
        );
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final settings = AppSettings(configDir: dir.path);
        addTearDown(settings.dispose);
        await settings.load();
        settings.dedupeImports = dedupe;
        final store = Store(settings);
        addTearDown(store.dispose);

        final json = File('${dir.path}/threads.json')
          ..writeAsStringSync(_twoThreadJson());
        await store.addJsonFiles([json.path]);
        expect(store.chats.keys, unorderedEquals(['alpha-id', 'beta-id']));
        final alphaCount = store.chats['alpha-id']!.messages.length;
        final betaCount = store.chats['beta-id']!.messages.length;

        store.removeChat(store.chats['beta-id']!);
        expect(settings.removedChats, contains('beta-id'));
        expect(settings.jsonPaths, contains(json.path));

        await store.addJsonFiles([json.path], reviveRemoved: true);
        expect(store.chats.keys, unorderedEquals(['alpha-id', 'beta-id']));
        expect(store.chats['alpha-id']!.messages, hasLength(alphaCount));
        expect(store.chats['beta-id']!.messages, hasLength(betaCount));
        expect(settings.removedChats, isNot(contains('beta-id')));

        // Re-picking the same file must not append a second copy.
        await store.addJsonFiles([json.path], reviveRemoved: true);
        expect(store.chats['alpha-id']!.messages, hasLength(alphaCount));
        expect(store.chats['beta-id']!.messages, hasLength(betaCount));
        expect(store.status, isNot(contains('Skipped')));
      }
    },
  );

  test(
    'media lookup keeps same-named files in different folders distinct',
    () async {
      final dir = await Directory.systemTemp.createTemp('indexed_paths_test_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final photos = Directory('${dir.path}/photos')
        ..createSync(recursive: true);
      final videos = Directory('${dir.path}/videos')
        ..createSync(recursive: true);
      final photo = File('${photos.path}/a.jpg')..writeAsStringSync('photo');
      final video = File('${videos.path}/a.jpg')..writeAsStringSync('video');
      final index = scanDirIndex(dir.path);
      expect(index.files['a.jpg'], isNotNull);

      final settings = AppSettings(configDir: dir.path);
      addTearDown(settings.dispose);
      await settings.load();
      final store = Store(settings);
      addTearDown(store.dispose);
      final chat = Chat('paths', 'Paths');
      chat.dirs.add(MediaDir(dir.path, index.files, index.paths));
      store.chats[chat.key] = chat;

      expect(store.findMedia('photos/a.jpg', chat), photo.path);
      expect(store.findMedia('videos/a.jpg', chat), video.path);
      expect(store.findMedia('a.jpg', chat), isNotNull);
    },
  );

  test('a stale media folder does not shadow a valid one', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_stale_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final valid = Directory('${dir.path}/valid')..createSync(recursive: true);
    final file = File('${valid.path}/a.jpg')..writeAsStringSync('image');

    final settings = AppSettings(configDir: dir.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);
    addTearDown(store.dispose);
    final chat = Chat('stale', 'Stale');
    chat.dirs.add(
      MediaDir(
        '${dir.path}/gone',
        {'a.jpg': '${dir.path}/gone/a.jpg'},
        {'photos/a.jpg': '${dir.path}/gone/a.jpg'},
      ),
    );
    chat.dirs.add(
      MediaDir(valid.path, {'a.jpg': file.path}, {'photos/a.jpg': file.path}),
    );
    store.chats[chat.key] = chat;

    expect(store.findMedia('photos/a.jpg', chat), file.path);
  });
}

String _twoThreadJson() => jsonEncode([
  <String, dynamic>{
    'threadId': 'alpha-id',
    'threadName': 'Alpha',
    'participants': [
      <String, dynamic>{'name': 'Ana'},
    ],
    'messages': [
      <String, dynamic>{
        'sender_name': 'Ana',
        'timestamp_ms': 1000,
        'content': 'alpha one',
      },
    ],
  },
  <String, dynamic>{
    'threadId': 'beta-id',
    'threadName': 'Beta',
    'participants': [
      <String, dynamic>{'name': 'Ben'},
    ],
    'messages': [
      <String, dynamic>{
        'sender_name': 'Ben',
        'timestamp_ms': 2000,
        'content': 'beta one',
      },
    ],
  },
]);

Msg _msg(
  String id,
  String sender,
  int t, {
  Reply? reply,
  List<Media> media = const [],
  String text = 'hello',
}) => Msg(
  id: id,
  sender: sender,
  t: t,
  text: text,
  media: media,
  reactions: const [],
  share: '',
  type: 'text',
  unsent: false,
  reply: reply,
  raw: const {},
);
