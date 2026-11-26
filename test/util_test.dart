// Small text helpers used by search and results panels.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fb_viewer/util.dart';

void main() {
  test('highlightSpans does not mis-slice Turkish dotted I', () {
    final spans = highlightSpans('İstanbul', 'i', null, kHighlightColor);
    expect(spans, hasLength(2));
    expect(spans.whereType<TextSpan>().map((s) => s.text).join(), 'İstanbul');
    expect((spans.first as TextSpan).text, 'İ');
  });

  test('highlightSpans still highlights ordinary case-insensitive matches', () {
    final spans = highlightSpans('Ana and ana', 'ANA', null, kHighlightColor);
    expect(spans.length, 3);
    expect(
      spans.whereType<TextSpan>().map((s) => s.text).join(),
      'Ana and ana',
    );
  });

  test('highlightSpans can match exactly when case sensitivity is enabled', () {
    final spans = highlightSpans(
      'Ana ana',
      'Ana',
      null,
      kHighlightColor,
      caseSensitive: true,
    );
    expect(spans.length, 2);
    expect((spans.first as TextSpan).text, 'Ana');
    expect(spans.last as TextSpan, isA<TextSpan>());
    expect((spans.last as TextSpan).text, ' ana');
  });

  test('snippet stays readable around a match in a long Unicode string', () {
    final text = 'İ😆${'a' * 200}needle${'b' * 200}';
    final got = snippet(text, 'needle');
    expect(got, contains('needle'));
    expect(got.length, lessThan(text.length));
    expect(got.startsWith('…'), isTrue);
    expect(got.endsWith('…'), isTrue);
  });

  test('snippet honours case-sensitive searching', () {
    final text = '${'a' * 100}Needle need${'b' * 100}';
    final got = snippet(text, 'Needle', caseSensitive: true);
    expect(got, contains('Needle'));
    expect(got.length, lessThan(text.length));
  });

  test('nextMatchPosition wraps in both directions', () {
    const matches = [3, 7, 9];
    expect(nextMatchPosition(null, matches, 1), 0);
    expect(nextMatchPosition(null, matches, -1), 2);
    expect(nextMatchPosition(7, matches, 1), 2);
    expect(nextMatchPosition(9, matches, 1), 0);
    expect(nextMatchPosition(3, matches, -1), 2);
    expect(nextMatchPosition(0, const <int>[], 1), -1);
  });

  test('sameMinute groups wall-clock minutes, not fixed 60-second windows', () {
    final base = DateTime(2026, 11, 26, 13, 59, 50).millisecondsSinceEpoch;
    expect(sameMinute(base, base + 9000), isTrue);
    expect(sameMinute(base, base + 11000), isFalse);
    expect(sameMinute(null, null), isTrue);
    expect(sameMinute(base, null), isFalse);
  });

  test('formatCount groups thousands', () {
    expect(formatCount(1), '1');
    expect(formatCount(999), '999');
    expect(formatCount(20000), '20,000');
    expect(formatCount(1234567), '1,234,567');
  });

  test('firstIndexAtOrAfter finds the first message on a picked date', () {
    final times = [_At(1000), _At(2000), _At(2000), _At(3000)];
    expect(firstIndexAtOrAfter(times, 2000, (x) => x.t), 1);
    expect(firstIndexAtOrAfter(times, 1500, (x) => x.t), 1);
    expect(firstIndexAtOrAfter(times, 4000, (x) => x.t), 4);
    expect(firstIndexAtOrAfter(const <_At>[], 0, (x) => x.t), 0);
  });

  test(
    'firstIndexAtOrAfter also walks newest-first views in reading order',
    () {
      final times = [_At(3000), _At(2000), _At(2000), _At(1000)];
      expect(firstIndexAtOrAfter(times, 2000, (x) => x.t, descending: true), 1);
      expect(firstIndexAtOrAfter(times, 2500, (x) => x.t, descending: true), 1);
      expect(firstIndexAtOrAfter(times, 4000, (x) => x.t, descending: true), 0);
      expect(firstIndexAtOrAfter(times, 500, (x) => x.t, descending: true), 4);
      expect(
        firstIndexAtOrAfter(const <_At>[], 0, (x) => x.t, descending: true),
        0,
      );
    },
  );

  test('isFastScroll reacts to flicks, not slow drags', () {
    expect(isFastScroll(300, 100), isTrue);
    expect(isFastScroll(-300, 100), isTrue);
    expect(isFastScroll(20, 100), isFalse);
    expect(isFastScroll(300, 0), isFalse);
  });
}

class _At {
  final int t;
  const _At(this.t);
}
