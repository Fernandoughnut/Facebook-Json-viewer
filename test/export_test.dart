// Export output is a stable, documented format and respects display names/filters.

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/exporter.dart';
import 'package:fb_viewer/models.dart';
import 'package:fb_viewer/parser.dart';
import 'package:fb_viewer/settings.dart';

const fixture = 'test/fixtures/test_message.json';

void main() {
  test('clean JSON has no raw fields and includes metadata', () {
    final settings = AppSettings();
    final chat = _chat();
    final json = chatToJson(chat, chat.messages, settings: settings)
      ..remove('exportedAt');

    expect(json['format'], 'messages-viewer/1');
    expect(json['messageCount'], 74);
    expect(json['title'], chat.title);
    final first = (json['messages'] as List).first as Map;
    expect(first.containsKey('raw'), isFalse);
    expect(first['sender'], 'Kenneth Almazar');
    expect(first['timestampMs'], 1795146913127);
    expect(first['date'], isA<String>());
  });

  test('aliases are used in exports with the original name preserved', () {
    final settings = AppSettings()..aliases['Kenneth Almazar'] = 'Ken';
    final chat = _chat();
    final msgs = chat.messages.take(1).toList();
    final json = chatToJson(chat, msgs, settings: settings)
      ..remove('exportedAt');

    final first = (json['messages'] as List).single as Map;
    expect(first['sender'], 'Ken');
    expect(first['senderOriginal'], 'Kenneth Almazar');
    expect(json['participants'], contains('Fernando A. Trestiza'));
  });

  test('CSV omits original names when display names are disabled', () {
    final settings = AppSettings()..aliases['Kenneth Almazar'] = 'Ken';
    final chat = _chat();
    final csv = messagesToCsv(
      chat.messages.take(1),
      settings,
      options: const ExportOptions(useDisplayNames: false),
    );
    final rows = csv.split('\n');
    final header = rows.first.split(',');
    final column = header.indexOf('senderOriginal');
    expect(rows[1].split(',')[column], '');
  });

  test('CSV quotes commas and newlines correctly', () {
    final settings = AppSettings();
    final m = Msg(
      id: 'id1',
      sender: 'Ana',
      t: 1700000000000,
      text: 'hello, "world"\nsecond line',
      media: const [],
      reactions: const [],
      share: '',
      type: 'text',
      unsent: false,
      reply: null,
      raw: const {},
    );
    final csv = messagesToCsv([m], settings);
    expect(csv, contains('"hello, ""world""\nsecond line"'));
  });

  test('withRaw keeps original data when explicitly requested', () {
    final settings = AppSettings();
    final chat = _chat();
    final json = chatToJson(
      chat,
      chat.messages.take(1).toList(),
      settings: settings,
      options: ExportOptions.withRaw,
    )..remove('exportedAt');
    expect(((json['messages'] as List).single as Map)['raw'], isA<Map>());
  });
}

Chat _chat() {
  final t = parseFile(fixture).single;
  final c = Chat(t.key, t.title);
  c.participants.addAll(t.participants);
  c.messages.addAll(t.messages);
  return c;
}
