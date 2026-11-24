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
      final dir = await Directory.systemTemp.createTemp(
        'fb_viewer_store_test_',
      );
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
    final dir = await Directory.systemTemp.createTemp('fb_viewer_store_test_');
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
    final dir = await Directory.systemTemp.createTemp('fb_viewer_store_test_');
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
    final dir = await Directory.systemTemp.createTemp('fb_viewer_store_test_');
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
}

Msg _msg(
  String id,
  String sender,
  int t, {
  Reply? reply,
  List<Media> media = const [],
}) => Msg(
  id: id,
  sender: sender,
  t: t,
  text: 'hello',
  media: media,
  reactions: const [],
  share: '',
  type: 'text',
  unsent: false,
  reply: reply,
  raw: const {},
);
