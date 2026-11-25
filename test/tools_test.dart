// Logic behind the Insights tab. No widgets are pumped here.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/tools_screen.dart';

void main() {
  test(
    'analyzeInsightsRows counts messages and orders months chronologically',
    () {
      final jan = DateTime(2024, 1, 15).millisecondsSinceEpoch;
      final feb = DateTime(2024, 2, 15).millisecondsSinceEpoch;

      final result = analyzeInsightsRows({
        'rows': [
          [
            'c1',
            'Chat One',
            'Ana',
            jan,
            'hello world',
            1,
            0,
            0,
            ['❤'],
          ],
          ['c1', 'Chat One', 'Ben', feb, 'hello there', 0, 1, 1, []],
          ['c2', 'Chat Two', 'Ana', feb, 'world', 0, 0, 0, []],
        ],
      });

      expect(result['msgCount'], 3);
      expect(result['chatCount'], 2);
      expect(result['reactions'], 1);
      expect(result['media'], 1);
      expect(result['links'], 1);
      expect(result['replies'], 1);
      expect(result['responseCount'], 1);

      final senders = result['topSenders'] as List<dynamic>;
      expect(senders.first[0], 'Ana');
      expect(senders.first[1], 2);

      final months = result['months'] as List<dynamic>;
      expect(months.map((m) => m[0]).toList(), ['2024-01', '2024-02']);
      expect(months.last[1], 2);

      final gaps = result['gaps'] as List<dynamic>;
      expect(gaps, hasLength(1));
      expect(gaps.single[1], 'Chat One');

      final words = result['wordsBySender'] as Map<String, dynamic>;
      final anaWords = words['Ana'] as List<dynamic>;
      expect(anaWords.any((w) => w[0] == 'world' && w[1] == 2), isTrue);
    },
  );

  test('insights analysis crosses the compute isolate boundary', () async {
    final result = await compute(analyzeInsightsRows, {
      'rows': [
        [
          'c1',
          'Chat One',
          'Ana',
          DateTime(2024, 3, 1).millisecondsSinceEpoch,
          'hello',
          0,
          0,
          0,
          <String>[],
        ],
      ],
    });

    expect(result['msgCount'], 1);
    expect(result['chatCount'], 1);
  });
}
