// Keep the About page honest: its version must match the published package.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/about_screen.dart';

void main() {
  test('About version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $appVersion+$appBuild'));
    expect(appVersionLabel, '1.5.1+5');
  });

  test('About links stay on the project repository', () {
    for (final url in [appRepoUrl, appReleasesUrl, appChangelogUrl]) {
      expect(Uri.parse(url).scheme, 'https');
      expect(url, startsWith(appRepoUrl));
    }
  });
}
