// Parser regression tests, using a real modern Messenger export as the fixture.

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
    expect(parseReply({'reply_to': 'abc'})!.id, 'abc');
    expect(parseReply({'replyToMessageId': 'xyz'})!.id, 'xyz');
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
}
