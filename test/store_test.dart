// Store-level state that must not leak between conversations.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/models.dart';
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
}

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
