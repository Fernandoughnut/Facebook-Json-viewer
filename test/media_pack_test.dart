// A conversation's media pack must include only referenced files, avoid
// duplicates, and keep the hashed export names traceable.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/media_pack.dart';
import 'package:fb_viewer/models.dart';

void main() {
  test('packed names cannot escape the archive or disappear', () {
    expect(packFileName(r'..\hash.jpg'), '_hash.jpg');
    expect(packFileName('/tmp/hash.jpg'), '_tmp_hash.jpg');
    expect(packFileName('..'), 'media');
  });

  test('planning deduplicates paths and makes readable unique names', () {
    final messages = [
      _msg(0, 'A', '2024-01-01', [Media('photos', 'pics/aaaa.jpg')]),
      _msg(0, 'A', '2024-01-02', [Media('photos', 'other/aaaa.jpg')]),
      _msg(2, 'A', '2024-01-03', [Media('photos', 'pics/aaaa.jpg')]),
    ];
    final paths = {
      'pics/aaaa.jpg': '/pics/aaaa.jpg',
      'other/aaaa.jpg': '/other/aaaa.jpg',
    };
    final plan = planMediaPack(
      messages,
      findMedia: (uri) => paths[uri],
      dateLabel: (t) => t == null ? 'unknown' : 'D$t',
      displayName: (s) => s == 'A' ? 'Alice' : s,
    );

    expect(plan.files.map((f) => f.path), [
      '/pics/aaaa.jpg',
      '/other/aaaa.jpg',
    ]);
    expect(plan.files.map((f) => f.name), [
      'D0_Alice_aaaa.jpg',
      'D0_Alice_aaaa_1.jpg',
    ]);
    expect(plan.references, hasLength(3));
    expect(plan.references.last.packedAs, 'media/D0_Alice_aaaa.jpg');
    expect(plan.missing, isEmpty);
  });

  test('missing and empty media references are handled separately', () {
    final plan = planMediaPack(
      [
        _msg(0, 'A', 'D1', [Media('photos', 'pics/gone.jpg')]),
        _msg(1, 'A', 'D2', [Media('sticker', '')]),
      ],
      findMedia: (_) => null,
      dateLabel: (t) => t == null ? 'unknown' : 'D$t',
    );

    expect(plan.files, isEmpty);
    expect(plan.references, isEmpty);
    expect(plan.missing, ['gone.jpg']);
  });

  test(
    'manifest records every reference without altering the export shape',
    () {
      final plan = planMediaPack(
        [
          _msg(0, 'A', 'D1', [Media('photos', 'pics/aaaa.jpg')]),
        ],
        findMedia: (_) => '/pics/aaaa.jpg',
        dateLabel: (t) => t == null ? 'unknown' : 'D$t',
      );
      final manifest = mediaPackManifest(
        title: 'Friends',
        key: 'k1',
        plan: plan,
      )..remove('exportedAt');

      expect(manifest['format'], 'indexed-media-pack/1');
      expect(manifest['fileCount'], 1);
      expect(manifest['referenceCount'], 1);
      expect((manifest['files'] as List).single, 'media/D0_A_aaaa.jpg');
      final ref = (manifest['references'] as List).single as Map;
      expect(ref['uri'], 'pics/aaaa.jpg');
      expect(ref['originalName'], 'aaaa.jpg');
      expect(ref['packedAs'], 'media/D0_A_aaaa.jpg');
    },
  );

  test('buildMediaZip stores original bytes and documents', () async {
    final dir = await Directory.systemTemp.createTemp('indexed-pack-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/a.jpg')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final zipPath = '${dir.path}/out.zip';

    final written = await buildMediaZip(<String, dynamic>{
      'zipPath': zipPath,
      'documents': [
        ['manifest.json', '{"ok":true}'],
      ],
      'files': [
        [source.path, 'media/a.jpg'],
      ],
    });

    expect(written, 1);
    final archive = ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());
    expect(
      archive.files.map((f) => f.name),
      containsAll(<String>['manifest.json', 'media/a.jpg']),
    );
    expect(
      archive.findFile('media/a.jpg')!.content,
      orderedEquals([1, 2, 3, 4]),
    );
  });
}

Msg _msg(int t, String sender, String date, List<Media> media) => Msg(
  id: 'm$t',
  sender: sender,
  t: t,
  // The plan only sees timestamps through dateLabel, so a tiny integer keeps
  // the expectations readable.
  text: date,
  media: media,
  reactions: const [],
  share: '',
  type: 'text',
  unsent: false,
  reply: null,
  raw: const {},
);
