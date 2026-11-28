// Pure helper regressions: search matching, media indexing and file-name
// helpers. No widget tree is needed for these.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/exporter.dart';
import 'package:fb_viewer/media_pack.dart';
import 'package:fb_viewer/models.dart';
import 'package:fb_viewer/settings.dart';
import 'package:fb_viewer/util.dart';

Msg _msg({
  String sender = 'Someone',
  String text = 'A normal message',
  String share = '',
  List<Media> media = const [],
}) => Msg(
  id: '1',
  sender: sender,
  t: 1,
  text: text,
  media: media,
  reactions: const [],
  share: share,
  type: 'Generic',
  unsent: false,
  reply: null,
  raw: const {},
);

void main() {
  tearDown(() => gSettings = null);

  test('messageMatches uses lowercase text, sender, link and media fields', () {
    gSettings = AppSettings();
    final m = _msg(
      sender: 'SoMeOne',
      text: 'Needle in a Haystack',
      share: 'HTTP://Example.COM/story',
      media: const [Media('photos', 'pics/PHOTO.JPG')],
    );

    expect(messageMatches(m, 'needle'), isTrue);
    expect(messageMatches(m, 'someone'), isTrue);
    expect(messageMatches(m, 'example.com'), isTrue);
    expect(messageMatches(m, 'photo.jpg'), isTrue);
    expect(messageMatches(m, 'absent'), isFalse);
    expect(messageMatches(m, '', sender: 'SoMeOne'), isTrue);
    expect(messageMatches(m, '', sender: 'Other'), isFalse);
    expect(messageMatches(m, '', mediaOnly: true), isTrue);
    expect(messageMatches(_msg(media: const []), '', mediaOnly: true), isFalse);
  });

  test('messageMatches accepts a pre-lowered query for bulk scans', () {
    gSettings = AppSettings();
    final m = _msg(sender: 'SoMeOne', text: 'Needle in a Haystack');

    expect(
      messageMatches(m, 'NEEDLE', lowerQuery: 'needle'),
      messageMatches(m, 'NEEDLE'),
    );
    expect(messageMatches(m, 'NEEDLE', lowerQuery: 'absent'), isFalse);
  });

  test('messageMatches finds a friend through the cached alias', () {
    final settings = AppSettings();
    settings.aliases['SoMeOne'] = 'Friendly Friend';
    gSettings = settings;
    final m = _msg(sender: 'SoMeOne');

    expect(messageMatches(m, 'friendly friend'), isTrue);
    expect(settings.lowerAliasFor('SoMeOne'), 'friendly friend');
  });

  test('MediaDir.suffixes indexes relative tails shortest first', () {
    final dir = MediaDir('/m', const {}, {
      'photos/a.jpg': '/m/photos/a.jpg',
      'videos/a.jpg': '/m/videos/a.jpg',
      'a.jpg': '/m/a.jpg',
    });

    expect(dir.suffixes['a.jpg'], [
      '/m/a.jpg',
      '/m/photos/a.jpg',
      '/m/videos/a.jpg',
    ]);
    expect(dir.suffixes['photos/a.jpg'], ['/m/photos/a.jpg']);
    expect(identical(dir.suffixes, dir.suffixes), isTrue);
  });

  test('jsonFilesIn finds nested JSON files only, in sorted order', () {
    final root = Directory.systemTemp.createTempSync('indexed_json_glob_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    File('${root.path}/b.json').writeAsStringSync('{}');
    File('${root.path}/a.json').writeAsStringSync('{}');
    Directory('${root.path}/nested').createSync();
    File('${root.path}/nested/c.JSON').writeAsStringSync('{}');
    File('${root.path}/notes.txt').writeAsStringSync('skip');

    expect(jsonFilesIn(root.path), [
      '${root.path}/a.json',
      '${root.path}/b.json',
      '${root.path}/nested/c.JSON',
    ]);
  });

  test('safeFileName sanitizes export titles for file names', () {
    expect(safeFileName('Friends / Family'), 'Friends _ Family');
    expect(safeFileName('a:b*c?d"e<f>g|h'), 'a_b_c_d_e_f_g_h');
    expect(safeFileName('  '), 'conversation');
  });

  test('mediaNamingFrom defaults to portable original names', () {
    expect(mediaNamingFrom(null), MediaNamingMode.originalSorted);
    expect(mediaNamingFrom('unknown'), MediaNamingMode.originalSorted);
    expect(mediaNamingFrom('readableDate'), MediaNamingMode.readableDate);
  });

  test('isWebLink only accepts http and https URLs', () {
    expect(isWebLink('https://example.com/a'), isTrue);
    expect(isWebLink('http://example.com'), isTrue);
    expect(isWebLink('file:///tmp/a.mp4'), isFalse);
    expect(isWebLink('/tmp/a.mp4'), isFalse);
  });
}
