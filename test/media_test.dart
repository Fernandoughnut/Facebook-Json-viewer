// Duplicate detection must run off the UI thread and ignore unique files.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/models.dart';
import 'package:fb_viewer/settings.dart';
import 'package:fb_viewer/store.dart';

void main() {
  test('duplicateMedia groups identical files by streamed hash', () async {
    final dir = await Directory.systemTemp.createTemp('indexed_media_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final a = File('${dir.path}${Platform.pathSeparator}a.jpg')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
    final b = File('${dir.path}${Platform.pathSeparator}b.jpg')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
    final c = File('${dir.path}${Platform.pathSeparator}c.jpg')
      ..writeAsBytesSync(List<int>.filled(2048, 9));
    final empty = File('${dir.path}${Platform.pathSeparator}empty.jpg')
      ..writeAsBytesSync(const []);

    final settings = AppSettings(configDir: dir.path);
    final store = Store(settings);
    addTearDown(() {
      store.dispose();
      settings.dispose();
    });
    final chat = Chat('k', 'Test chat');
    chat.dirs.add(
      MediaDir(dir.path, {
        'a.jpg': a.path,
        'b.jpg': b.path,
        'c.jpg': c.path,
        'empty.jpg': empty.path,
      }),
    );
    store.chats[chat.key] = chat;

    final groups = await store.duplicateMedia();
    expect(groups.length, 1);
    expect(groups.values.single, hasLength(2));
    expect(groups.values.single, containsAll([a.path, b.path]));
  });
}
