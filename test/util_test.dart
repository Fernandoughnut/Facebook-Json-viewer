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
}
