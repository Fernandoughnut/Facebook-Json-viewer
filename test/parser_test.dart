// Parser regression tests, using a real modern Messenger export as the fixture.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/models.dart';
import 'package:fb_viewer/parser.dart';

void main() {
  const fixture = 'test/fixtures/test_message.json';

  test('parses the modern senderName/timestamp/text layout', () {
    final threads = parseFile(fixture);
    expect(threads, hasLength(1));

    final t = threads.single;
    expect(t.title, 'Kenneth Almazar_3');
    expect(t.participants, ['Fernando A. Trestiza', 'Kenneth Almazar']);
    expect(t.messages, hasLength(74));

    final first = t.messages.first;
    expect(first.sender, 'Kenneth Almazar');
    expect(first.text, 'Boii');
    expect(first.t, 1795146913127);
    expect(first.type, 'text');
    expect(first.media, isEmpty);
    expect(first.reactions, isEmpty);
  });

  test('reads media uris and reactions from the modern layout', () {
    final msgs = parseFile(fixture).single.messages;
    final withMedia = msgs.where((m) => m.media.isNotEmpty).toList();
    expect(withMedia, hasLength(1));
    expect(withMedia.single.media.single.kind, 'media');
    expect(withMedia.single.media.single.uri, contains('.jpeg'));
    expect(withMedia.single.media.single.name, isNotEmpty);

    final reacted = msgs.where((m) => m.reactions.isNotEmpty).toList();
    expect(reacted.length, greaterThan(0));
    final r = reacted.last.reactions.last;
    expect(r.actor, 'Kenneth Almazar');
    expect(r.emoji, '❤');
  });

  test('this export has no reply fields, so no message is a reply', () {
    final msgs = parseFile(fixture).single.messages;
    expect(msgs.every((m) => m.reply == null), isTrue);
  });

  test('timestamps accept seconds, milliseconds and ISO strings', () {
    expect(toMs(1700000000), 1700000000000);
    expect(toMs(1700000000000), 1700000000000);
    expect(toMs('1700000000'), 1700000000000);
    expect(toMs('2024-01-01T00:00:00Z'), isNotNull);
  });

  test('encoding repair leaves real Unicode and plain Latin-1 alone', () {
    expect(fixEnc('café'), 'café'); // U+00E9 must survive
    expect(fixEnc('emoji 😆'), 'emoji 😆'); // > 255 short-circuits
    expect(fixEnc('cafÃ©'), 'café'); // mojibake is repaired
  });

  test('reply variants are recognised', () {
    expect(parseReply({'reply_to_id': 'abc'})!.id, 'abc');
    expect(parseReply({'replyToMessageId': 'xyz'})!.id, 'xyz');
    expect(parseReply({'reply': true, 'reply_to_id': 'abc'})!.id, 'abc');
    final nested = parseReply({
      'quoted_message': {
        'message_id': 'q1',
        'sender_name': 'Ana',
        'content': 'original',
        'timestamp_ms': 1700000000000,
      },
    })!;
    expect(nested.id, 'q1');
    expect(nested.sender, 'Ana');
    expect(nested.text, 'original');
    expect(nested.t, 1700000000000);
  });

  test('path separator splitting works for Windows and Linux exports', () {
    expect(Media('photos', r'C:\export\media\abc.jpg').name, 'abc.jpg');
    expect(Media('photos', './media/abc.jpg').name, 'abc.jpg');
  });

  test(
    'scanDir resolves case-only filename collisions deterministically',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'indexed_scan_dir_test_',
      );
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File('${dir.path}/a.jpg').writeAsStringSync('lower');
      File('${dir.path}/A.jpg').writeAsStringSync('upper');
      File('${dir.path}/broken.jpg.part').writeAsStringSync('partial');
      File('${dir.path}/broken.jpg.tmp').writeAsStringSync('partial');

      final scanned = scanDir(dir.path);
      expect(scanned['a.jpg'], endsWith('A.jpg'));
      expect(scanned.containsKey('broken.jpg.part'), isFalse);
      expect(scanned.containsKey('broken.jpg.tmp'), isFalse);
    },
  );

  test(
    'scanDirIndex preserves relative folders for duplicate file names',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'indexed_scan_index_test_',
      );
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final photos = Directory('${dir.path}/photos')
        ..createSync(recursive: true);
      final videos = Directory('${dir.path}/videos')
        ..createSync(recursive: true);
      File('${photos.path}/a.jpg').writeAsStringSync('photo');
      File('${videos.path}/a.jpg').writeAsStringSync('video');

      final index = scanDirIndex(dir.path);
      expect(index.files['a.jpg'], isNotNull);
      expect(index.paths['photos/a.jpg'], endsWith('photos/a.jpg'));
      expect(index.paths['videos/a.jpg'], endsWith('videos/a.jpg'));
      expect(index.paths['photos/a.jpg'], isNot(index.paths['videos/a.jpg']));
    },
  );

  test(
    'encoding repair handles non-Latin mojibake mixed with real Unicode',
    () {
      String mojibake(String s) => String.fromCharCodes(utf8.encode(s));
      expect(fixEnc(mojibake('你好 😆')), '你好 😆');
      expect(fixEnc(mojibake('Привет')), 'Привет');
      expect(fixEnc(mojibake('Ελληνικά')), 'Ελληνικά');
      expect(fixEnc('你好 😆'), '你好 😆');
      expect(fixEnc('café'), 'café');
    },
  );

  test('timestamp hints keep explicit milliseconds but fix microseconds', () {
    expect(toMs(1700000000000000), 1700000000000);
    expect(toMsWithHint(1700000000000000, 'timestamp_ms'), 1700000000000000);
    expect(timeOf({'timestampMs': 1700000000000000}), 1700000000000000);
  });

  test('bare replies distinguish short text from real IDs', () {
    expect(parseReply({'reply_to': 'ok'})!.text, 'ok');
    expect(parseReply({'reply_to': 'ok'})!.id, isEmpty);
    expect(parseReply({'reply': 'ok'})!.text, 'ok');
    expect(parseReply({'reply': 'abc123def456'})!.id, 'abc123def456');
    expect(parseReply({'reply': '👍'})!.text, '👍');
    expect(parseReply({'reply': '👍'})!.id, isEmpty);
  });

  test('timestamped media-only and sticker-only messages survive parsing', () {
    final exported = <String, dynamic>{
      'threadId': 'media-only',
      'threadName': 'Media',
      'participants': [
        <String, dynamic>{'name': 'Ana'},
      ],
      'messages': [
        <String, dynamic>{
          'timestamp_ms': 1000,
          'photos': [
            <String, dynamic>{'uri': 'photos/a.jpg'},
          ],
        },
        <String, dynamic>{'timestamp_ms': 2000, 'sticker': 'stickers/s.png'},
      ],
    };
    final thread = parseExport(exported, 'media-only.json').single;
    expect(thread.messages, hasLength(2));
    expect(thread.messages[0].media.single.uri, 'photos/a.jpg');
    expect(thread.messages[1].media.single.kind, 'sticker');
    expect(thread.messages[1].media.single.uri, 'stickers/s.png');
  });

  test('export aliases never overwrite original identities on re-import', () {
    final raw = <String, dynamic>{
      'sender': 'A',
      'senderOriginal': 'Ana',
      'timestamp_ms': 1000,
      'content': 'hello',
      'share': 'https://example.invalid/a',
      'reactions': [
        <String, dynamic>{'emoji': '👍', 'actor': 'B', 'actorOriginal': 'Ben'},
      ],
      'reply': <String, dynamic>{
        'id': 'm0',
        'sender': 'B',
        'senderOriginal': 'Ben',
        'text': 'earlier',
      },
    };
    final msg = normMsg(raw);
    expect(msg.sender, 'Ana');
    expect(msg.share, 'https://example.invalid/a');
    expect(msg.reactions.single.actor, 'Ben');
    expect(msg.reply!.sender, 'Ben');

    final thread = parseExport(<String, dynamic>{
      'threadId': 'aliases',
      'threadName': 'Aliases',
      'participants': ['A', 'B'],
      'participantsOriginal': ['Ana', 'Ben'],
      'messages': [raw],
    }, 'aliases.json').single;
    expect(thread.participants, ['Ana', 'Ben']);
  });
}
