// Synthetic export generator + simple parse benchmark.
//
// dart run tool/generate_large_export.dart 100000 /tmp/opencode/large_export.json

import 'dart:convert';
import 'dart:io';

import 'package:fb_viewer/parser.dart';

void main(List<String> args) {
  final count = args.isNotEmpty ? int.tryParse(args[0]) ?? 100000 : 100000;
  final outPath = args.length > 1 ? args[1] : '${Directory.systemTemp.path}/indexed_large_export.json';
  final start = DateTime(2020, 1, 1).millisecondsSinceEpoch;
  final people = ['Ana', 'Ben', 'Carla'];

  final messages = <Map<String, dynamic>>[];
  for (var i = 0; i < count; i++) {
    final m = <String, dynamic>{
      'senderName': people[i % people.length],
      'timestamp': start + i * 60000,
      'type': 'text',
      'text': 'Message $i: the quick brown fox jumps over the lazy dog',
      'reactions': <dynamic>[],
      'media': <dynamic>[],
      'isUnsent': false,
    };
    if (i % 97 == 0) {
      m['reactions'] = [
        {'actor': people[(i + 1) % people.length], 'reaction': '❤'}
      ];
    }
    if (i % 251 == 0) {
      m['media'] = [
        {'uri': './media/${i.toString().padLeft(8, '0')}.jpg'}
      ];
    }
    if (i % 1009 == 0 && i >= 1009) {
      m['replyToMessageId'] = 'm${i - 1009}';
    }
    m['messageId'] = 'm$i';
    messages.add(m);
  }

  final root = <String, dynamic>{
    'participants': people,
    'threadName': 'Synthetic benchmark',
    'messages': messages,
  };
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(jsonEncode(root));

  final sw = Stopwatch()..start();
  final threads = parseFile(out.path);
  sw.stop();
  final total = threads.fold<int>(0, (n, t) => n + t.messages.length);
  stdout.writeln('Wrote $count messages to ${out.path} (${(out.lengthSync() / 1e6).toStringAsFixed(1)} MB)');
  stdout.writeln('Parsed $total messages in ${sw.elapsedMilliseconds} ms');
}
