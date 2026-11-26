// A conversation's media pack must include only referenced files, avoid
// duplicates, and keep the hashed export names traceable.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/media_pack.dart';
import 'package:fb_viewer/models.dart';

void main() {
  test('pack file names are stable and avoid same-second collisions', () {
    final first = mediaPackFileName(
      'Friends',
      DateTime(2024, 1, 2, 3, 4, 5, 678),
    );
    final second = mediaPackFileName(
      'Friends',
      DateTime(2024, 1, 2, 3, 4, 5, 679),
    );

    expect(first, 'Friends_media_2024-01-02_030405_678.zip');
    expect(second, 'Friends_media_2024-01-02_030405_679.zip');
  });

  test('packed names cannot escape the archive or disappear', () {
    expect(packFileName(r'..\hash.jpg'), '_hash.jpg');
    expect(packFileName('/tmp/hash.jpg'), '_tmp_hash.jpg');
    expect(packFileName('..'), 'media');
    expect(packFileName('photo.jpg.'), 'photo.jpg');
    expect(packFileName('CON'), '_CON');
    expect(packFileName('nul.txt'), '_nul.txt');
    expect(packFileName('${'a' * 200}.jpg').length, 180);
  });

  test('readable date names stay unique and dedupe resolved paths', () {
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
      options: const MediaPackOptions(naming: MediaNamingMode.readableDate),
    );

    expect(plan.files.map((f) => f.path), [
      '/pics/aaaa.jpg',
      '/other/aaaa.jpg',
    ]);
    expect(plan.files.map((f) => f.name), [
      'media/D0_Alice_aaaa.jpg',
      'media/D0_Alice_aaaa_1.jpg',
    ]);
    expect(plan.references, hasLength(3));
    expect(plan.references.last.packedAs, 'media/D0_Alice_aaaa.jpg');
    expect(plan.duplicateReferences, 1);
    expect(plan.missing, isEmpty);
  });

  test('original names keep the relative path and sort chronologically', () {
    final messages = [
      _msg(2, 'A', '2024-01-03', [Media('photos', 'pics/b.jpg')]),
      _msg(0, 'A', '2024-01-01', [Media('photos', 'pics/a.jpg')]),
    ];
    final paths = {'pics/a.jpg': '/real/a.jpg', 'pics/b.jpg': '/real/b.jpg'};
    final plan = planMediaPack(
      messages,
      findMedia: (uri) => paths[uri],
      dateLabel: (_) => 'unused',
      options: const MediaPackOptions(naming: MediaNamingMode.originalSorted),
    );

    expect(plan.files.map((f) => f.name), [
      'media/pics/a.jpg',
      'media/pics/b.jpg',
    ]);
    expect(plan.files.map((f) => f.path), ['/real/a.jpg', '/real/b.jpg']);
    expect(plan.references.map((r) => r.packedAs), [
      'media/pics/b.jpg',
      'media/pics/a.jpg',
    ]);
    expect(plan.naming, MediaNamingMode.originalSorted);
  });

  test('missing, empty and duplicate references are counted separately', () {
    final plan = planMediaPack(
      [
        _msg(0, 'A', 'D1', [Media('photos', 'pics/gone.jpg')]),
        _msg(1, 'A', 'D2', [Media('sticker', '')]),
        _msg(2, 'A', 'D3', [Media('photos', 'pics/twice.jpg')]),
        _msg(3, 'A', 'D4', [Media('photos', 'pics/twice.jpg')]),
      ],
      findMedia: (uri) =>
          uri.contains('gone') ? null : '/fake/${uri.split('/').last}',
      dateLabel: (t) => t == null ? 'unknown' : 'D$t',
    );

    expect(plan.files, hasLength(1));
    expect(plan.references, hasLength(2));
    expect(plan.missing, ['gone.jpg']);
    expect(plan.emptyReferences, 1);
    expect(plan.duplicateReferences, 1);
  });

  test(
    '3400 references to 2000 paths produce 2000 files, not a truncated pack',
    () {
      final messages = <Msg>[];
      final paths = <String, String>{};
      for (var i = 0; i < 3400; i++) {
        final uri = 'photos/${i % 2000}.jpg';
        paths.putIfAbsent(uri, () => '/fake/${i % 2000}.jpg');
        messages.add(_msg(i, 'A', 'D$i', [Media('photos', uri)]));
      }
      final plan = planMediaPack(
        messages,
        findMedia: (uri) => paths[uri],
        dateLabel: (t) => t == null ? 'unknown' : 'D$t',
      );
      final manifest = mediaPackManifest(title: 'Big', plan: plan)
        ..remove('exportedAt');

      expect(plan.references, hasLength(3400));
      expect(plan.files, hasLength(2000));
      expect(plan.duplicateReferences, 1400);
      expect(manifest['fileCount'], 2000);
      expect(manifest['referenceCount'], 3400);
      expect(manifest['duplicateReferences'], 1400);
      expect((manifest['files'] as List).toSet(), hasLength(2000));
    },
  );

  test('duplicate references can optionally be packed as separate entries', () {
    final plan = planMediaPack(
      [
        _msg(0, 'A', 'D1', [Media('photos', 'pics/a.jpg')]),
        _msg(1, 'A', 'D2', [Media('photos', 'pics/a.jpg')]),
      ],
      findMedia: (_) => '/fake/a.jpg',
      dateLabel: (t) => t == null ? 'unknown' : 'D$t',
      options: const MediaPackOptions(keepDuplicateReferences: true),
    );

    expect(plan.files.map((f) => f.name), [
      'media/pics/a.jpg',
      'media/pics/a_1.jpg',
    ]);
    expect(plan.duplicateReferences, 0);
    expect(plan.references.map((r) => r.packedAs), [
      'media/pics/a.jpg',
      'media/pics/a_1.jpg',
    ]);
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
        options: const MediaPackOptions(naming: MediaNamingMode.readableDate),
      );
      final manifest = mediaPackManifest(
        title: 'Friends',
        key: 'k1',
        plan: plan,
      )..remove('exportedAt');

      expect(manifest['format'], 'indexed-media-pack/1');
      expect(manifest['naming'], 'readableDate');
      expect(manifest['order'], 'chronological');
      expect(manifest['fileCount'], 1);
      expect(manifest['referenceCount'], 1);
      expect((manifest['files'] as List).single, 'media/D0_A_aaaa.jpg');
      final ref = (manifest['references'] as List).single as Map;
      expect(ref['uri'], 'pics/aaaa.jpg');
      expect(ref['originalName'], 'aaaa.jpg');
      expect(ref['packedAs'], 'media/D0_A_aaaa.jpg');
    },
  );

  test('files that vanish after indexing are removed from the plan', () async {
    final dir = await Directory.systemTemp.createTemp('indexed-pack-prune-');
    addTearDown(() => dir.delete(recursive: true));
    final kept = File('${dir.path}/kept.jpg')..writeAsBytesSync([1]);
    final gone = File('${dir.path}/gone.jpg')..writeAsBytesSync([2]);
    final plan = planMediaPack(
      [
        _msg(0, 'A', 'D1', [Media('photos', 'pics/kept.jpg')]),
        _msg(1, 'A', 'D2', [Media('photos', 'pics/gone.jpg')]),
      ],
      findMedia: (uri) => uri.contains('kept') ? kept.path : gone.path,
      dateLabel: (t) => t == null ? 'unknown' : 'D$t',
    );
    gone.deleteSync();

    final pruned = pruneUnreadableMediaPack(plan);
    expect(pruned.files, hasLength(1));
    expect(pruned.files.single.path, kept.path);
    expect(pruned.unreadable, ['media/pics/gone.jpg']);
    expect(pruned.missing, ['gone.jpg']);
    expect(mediaPackManifest(title: 'x', plan: pruned)['fileCount'], 1);
  });

  test(
    'buildMediaZip stores original bytes and reports skipped sources',
    () async {
      final dir = await Directory.systemTemp.createTemp('indexed-pack-');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/a.jpg')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final zipPath = '${dir.path}/out.zip';

      final result = await buildMediaZip(<String, dynamic>{
        'zipPath': zipPath,
        'documents': [
          ['manifest.json', '{"ok":true}'],
        ],
        'files': [
          [source.path, 'media/a.jpg'],
          ['${dir.path}/gone.jpg', 'media/gone.jpg'],
        ],
      });

      expect(result['written'], 1);
      expect(result['skipped'], ['media/gone.jpg']);
      final archive = ZipDecoder().decodeBytes(
        await File(zipPath).readAsBytes(),
      );
      expect(
        archive.files.map((f) => f.name),
        containsAll(<String>['manifest.json', 'media/a.jpg']),
      );
      expect(
        archive.findFile('media/a.jpg')!.content,
        orderedEquals([1, 2, 3, 4]),
      );
    },
  );
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
