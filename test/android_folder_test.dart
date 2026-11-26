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
}
