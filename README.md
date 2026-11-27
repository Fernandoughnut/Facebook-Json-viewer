# Indexed

A local viewer for Facebook / Messenger JSON exports. Read conversations, search and filter them, show the original media inline, and export what you need. Nothing is uploaded.

Available for **Linux** and **Android** (sideload APKs).

## Get started

1. Download the Linux bundle or an Android APK from the latest release.
2. Open one or more `.json` exports with **Open JSON**, or use **Import folder** for every `.json` file in a folder.
3. Set **I am** to your name and add your media folder(s).
4. Search, filter, export, or pack a conversation's media.

Removing a conversation only hides it locally; opening its JSON again restores it.

## Features

- Chat view with dates, reactions, replies, bookmarks, notes, three layouts, and saved reading position.
- Search by text, sender, media, regex and case; people filters and saved searches.
- Tools for insights, links, duplicates, missing media, and JSON / CSV / text export.
- Inline photos, gallery, full-screen viewer, and byte-preserving media packs.
- Material 3 or Classic themes, optional immersive reading, and a local PIN gate (a convenience lock, not encryption).

## Downloads

Each release includes:

- `Indexed-linux-x64-vX.Y.Z.tar.gz` — extract and run `./indexed`.
- `Indexed-universal-X.Y.Z.apk` and split APKs for `arm64-v8a`, `armeabi-v7a` and `x86_64`.
- A `.sha256` file for every asset.

Android APKs are debug-signed with application ID `dev.local.indexed`. Uninstall any older Indexed or `dev.local.fb_viewer` APK before installing.

## Build from source

You need Flutter stable. Linux also needs a C/C++ toolchain and GTK 3 development files.

```bash
flutter pub get
flutter analyze
flutter test
./tool/package_linux.sh Indexed-linux-x64.tar.gz
./tool/build_android.sh /tmp/opencode/indexed-android
```

The Linux executable is `build/linux/x64/release/bundle/indexed`; keep the whole bundle folder. The Android script produces a universal APK plus split APKs, each with a checksum.

## Notes

- Settings live in `~/.config/fb_viewer/state.json` on Linux and in app-private storage on Android.
- Android folder imports copy into app-private storage; source files are unchanged.
- HEIC photos cannot be displayed. Desktop drag-and-drop and a thumbnail cache are not implemented yet.
- Large exports parse in a background isolate with a persistent cache; raw JSON can be dropped to save memory.

Everything runs locally. Indexed does not upload messages, media or settings anywhere.
