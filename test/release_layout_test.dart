// Release packaging guards. These read the shipped scripts instead of building
// a bundle, so they stay fast and run on every platform.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Linux tar commands archive bundle contents with a trailing dot', () {
    final script = File('tool/package_linux.sh').readAsStringSync();
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    expect(
      script,
      contains(r'tar -czf "$ARCHIVE" -C build/linux/x64/release/bundle .'),
    );
    expect(
      workflow,
      contains(r'tar -czf "$ARCHIVE" -C build/linux/x64/release/bundle .'),
    );
  });

  test('Android APK checksums use bare downloaded file names', () {
    final script = File('tool/build_android.sh').readAsStringSync();
    expect(script.indexOf(r'cd "$OUT"'), lessThan(script.indexOf('sha256sum')));
    expect(script, contains(r'sha256sum "$f" > "$f.sha256"'));

    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    expect(workflow, contains('*.apk'));
    expect(workflow, contains('*.apk.sha256'));
    expect(workflow, contains('fail_on_unmatched_files: true'));
  });

  test('release assets stay out of Git and changelog describes 1.5.0', () {
    final ignore = File('.gitignore').readAsStringSync();
    for (final pattern in ['*.tar.gz', '*.sha256', '*.apk', '*.aab']) {
      expect(ignore, contains(pattern));
    }

    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(changelog, contains('## 1.5.0'));
    expect(changelog, contains('Android'));
  });
}
