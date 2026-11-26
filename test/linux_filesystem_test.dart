// Linux/desktop regression: the fixes must hold against real paths, not just
// in-memory maps. This covers explicit re-add, a 3400-reference pack over
// 2000 real files with duplicate basenames, and re-opening the extracted pack.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/exporter.dart';
import 'package:fb_viewer/media_pack.dart';
import 'package:fb_viewer/models.dart';
import 'package:fb_viewer/settings.dart';
import 'package:fb_viewer/store.dart';

void main() {
  test('Linux filesystem re-add, 3400-reference pack and extracted-folder round trip', () async {
    final root = await Directory.systemTemp.createTemp(
      'indexed_linux_roundtrip_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    // --- explicit re-add after removal -----------------------------------
    final config = Directory('${root.path}/config-a');
    final settings = AppSettings(configDir: config.path);
    addTearDown(settings.dispose);
    await settings.load();
    final store = Store(settings);
    addTearDown(store.dispose);

    final json = File('${root.path}/messages.json')
      ..writeAsStringSync(
        File('test/fixtures/test_message.json').readAsStringSync(),
      );
    await store.addJsonFiles([json.path]);
    final chat = store.chats.values.single;
    final key = chat.key;
    final originalCount = chat.messages.length;
    expect(originalCount, greaterThan(0));

    store.removeChat(chat);
    expect(store.chats, isEmpty);
    expect(settings.removedChats, contains(key));

    await store.addJsonFiles([json.path], reviveRemoved: true);
    final revived = store.chats[key];
    expect(revived, isNotNull);
    expect(revived!.messages, hasLength(originalCount));
    expect(settings.removedChats, isNot(contains(key)));

    // --- 3400 references over 2000 real, duplicate-named files -----------
    final mediaRoot = Directory('${root.path}/media-source')
      ..createSync(recursive: true);
    final photos = Directory('${mediaRoot.path}/photos')
      ..createSync(recursive: true);
    final videos = Directory('${mediaRoot.path}/videos')
      ..createSync(recursive: true);
    for (var i = 0; i < 1000; i++) {
      File('${photos.path}/$i.jpg').writeAsBytesSync([i ~/ 256, i % 256, 1]);
      File('${videos.path}/$i.jpg').writeAsBytesSync([i ~/ 256, i % 256, 2]);
    }

    final messages = <Msg>[];
    for (var i = 0; i < 3400; i++) {
      // The first 2000 references resolve to distinct paths; the last 1400
      // repeat earlier paths, while every folder has the same file names.
      final sub = i.isEven ? 'photos' : 'videos';
      final index = (i ~/ 2) % 1000;
      messages.add(
        Msg(
          id: 'm$i',
          sender: 'A',
          t: 1_700_000_000_000 + i,
          text: 'message $i',
          media: [Media('photos', '$sub/$index.jpg')],
          reactions: const [],
          share: '',
          type: 'text',
          unsent: false,
          reply: null,
          raw: const {},
        ),
      );
    }
    revived.messages
      ..clear()
      ..addAll(messages);

    await store.addMediaDir(mediaRoot.path);
    final plan = planMediaPack(
      messages,
      findMedia: (uri) => store.findMedia(uri, revived),
      dateLabel: (t) => 'D$t',
      options: const MediaPackOptions(naming: MediaNamingMode.originalSorted),
    );
    expect(plan.references, hasLength(3400));
    expect(plan.files, hasLength(2000));
    expect(plan.duplicateReferences, 1400);
    expect(plan.missing, isEmpty);
    expect(
      plan.files.map((f) => f.name).toSet(),
      containsAll(<String>[
        'media/photos/0.jpg',
        'media/photos/998.jpg',
        'media/videos/1.jpg',
        'media/videos/999.jpg',
      ]),
    );

    // --- export, then re-open the extracted folder as a media folder -----
    final zipPath = '${root.path}/pack.zip';
    final conversationJson = const JsonEncoder.withIndent('  ').convert(
      chatToJson(
        revived,
        messages,
        settings: settings,
        options: ExportOptions.clean,
      ),
    );
    final manifestJson = const JsonEncoder.withIndent('  ').convert(
      mediaPackManifest(title: revived.title, key: revived.key, plan: plan),
    );
    final result = await buildMediaZip(<String, dynamic>{
      'zipPath': zipPath,
      'documents': [
        ['conversation.json', conversationJson],
        ['manifest.json', manifestJson],
      ],
      'files': [
        for (final f in plan.files) [f.path, f.name],
      ],
    });
    expect(result['written'], 2000);
    expect(result['skipped'], isEmpty);

    final extracted = Directory('${root.path}/extracted')
      ..createSync(recursive: true);
    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    for (final entry in archive.files) {
      if (entry.isFile) {
        final out = File('${extracted.path}/${entry.name}')
          ..createSync(recursive: true);
        out.writeAsBytesSync(entry.content as List<int>);
      }
    }
    expect(
      File('${extracted.path}/media/photos/0.jpg').readAsBytesSync(),
      orderedEquals(File('${photos.path}/0.jpg').readAsBytesSync()),
    );

    final configB = Directory('${root.path}/config-b');
    final settingsB = AppSettings(configDir: configB.path);
    addTearDown(settingsB.dispose);
    await settingsB.load();
    final storeB = Store(settingsB);
    addTearDown(storeB.dispose);

    await storeB.addJsonFiles(['${extracted.path}/conversation.json']);
    final roundTripChat = storeB.chats.values.single;
    expect(roundTripChat.messages, hasLength(3400));
    await storeB.addMediaDir('${extracted.path}/media');
    final stats = storeB.statsFor(roundTripChat);
    expect(stats.total, 3400);
    expect(stats.fromChat + stats.fromShared, 3400);
    expect(stats.missing, 0);
  });
}
