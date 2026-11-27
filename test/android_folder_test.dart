// The Android folder importer uses a stable short hash as the on-disk folder
// name, so re-picking the same tree must map to the same directory.

import 'package:flutter_test/flutter_test.dart';
import 'package:fb_viewer/android_folder.dart';

void main() {
  test('folder name is stable, short, and distinct per URI', () {
    const uri =
        'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
    final name = AndroidFolderPicker.folderNameFor(uri);

    expect(name, hasLength(12));
    expect(name, matches(RegExp(r'^[0-9a-f]+$')));
    expect(name, AndroidFolderPicker.folderNameFor(uri));
    expect(name, isNot(AndroidFolderPicker.folderNameFor('$uri/other')));
    // Escape case is a provider detail, not a different folder.
    expect(
      name,
      AndroidFolderPicker.folderNameFor(uri.replaceFirst('%3A', '%3a')),
    );
  });

  test('a failed re-import keeps files from the earlier import', () {
    expect(shouldDiscardImportDir(existedBefore: false), isTrue);
    expect(shouldDiscardImportDir(existedBefore: true), isFalse);
  });

  test('progress is routed only to the matching running import', () {
    final router = ImportProgressRouter();
    final media = <Map<String, dynamic>>[];
    final json = <Map<String, dynamic>>[];
    router.register('media', media.add);
    router.register('json', json.add);

    router.dispatch('importProgress', {'importId': 'media', 'current': 3});
    router.dispatch('importProgress', {'importId': 'json', 'current': 7});
    router.dispatch('otherMethod', {'importId': 'media'});
    router.dispatch('importProgress', {'current': 9});
    router.dispatch('importProgress', 'not a map');

    expect(media, [
      {'importId': 'media', 'current': 3},
    ]);
    expect(json, [
      {'importId': 'json', 'current': 7},
    ]);

    router.unregister('media');
    router.dispatch('importProgress', {'importId': 'media', 'current': 4});
    expect(media, hasLength(1));
    expect(router.listenerCount, 1);
  });
}
