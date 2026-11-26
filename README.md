# Indexed

A local viewer and organizer for exported Facebook / Messenger messages. Open the JSON exports, read them as normal conversations, search and filter them, show the original photos inline, and export what you need. Everything stays on your device.

Available for **Linux** and **Android** (sideload APKs).

## Get started

1. Download the Linux bundle or an Android APK from the latest GitHub Release, or build from source below.
2. In Indexed, choose **Open JSON** and pick one or more exported `.json` files. You can also import every `.json` file in a folder; on Android this uses the system folder picker and copies the files into Indexed's private storage.
3. Pick a conversation, set **I am** to your name, and choose your media folder(s).
4. Search, filter, export, or pack the conversation's media as a ZIP.

If you removed a conversation, opening its JSON again brings it back. The original files are never deleted.

## What it does

- Reads regular and encrypted-chat exports, repairs common encoding problems, and merges split exports of the same chat.
- Chat view with date separators, reactions, reply quotes, bookmarks, notes, three layouts, and start-at-newest/oldest/last-position.
- Search by text, sender, media, regex and case. People filters live in their own dialog; saved searches are supported.
- Tools for bookmarks, insights, links and media cleanup, including duplicate detection and a missing-files report.
- Inline photos, gallery grid, full-screen viewer, shared and per-conversation media folders, and byte-for-byte media import.
- Conversation media packs: choose original sorted paths for a re-importable ZIP, or readable date/sender names for browsing.
- JSON / CSV / text export of the whole chat, the current filtered view, or a selection.
- Remembers the session, themes, filters and reading positions. Optional local PIN gate (a convenience lock, not encryption).
- Material 3 or Classic design, light/dark/system themes, optional immersive reading mode, and hideable activity/position bars.

## Downloads

Releases include:

- `Indexed-linux-x64-vX.Y.Z.tar.gz` — extract and run `./indexed` from the bundle.
- `Indexed-universal-X.Y.Z.apk` — works on every supported Android device.
- Smaller split APKs for `arm64-v8a`, `armeabi-v7a` and `x86_64`.
- A `.sha256` file for every asset.

The Android app is debug-signed for sideloading and uses application ID `dev.local.indexed`. Because the signing key is not a stable release key, uninstall any older Indexed APK before installing a new one. Uninstall any older `dev.local.fb_viewer` build too.

## Build from source

You need Flutter stable. Linux also needs a C/C++ toolchain and GTK 3 development files.

```bash
flutter pub get
flutter analyze
flutter test
```

Linux:

```bash
./tool/package_linux.sh Indexed-linux-x64.tar.gz
# or: flutter build linux --release
```

The Linux executable is `build/linux/x64/release/bundle/indexed`; distribute the whole bundle folder.

Android:

```bash
./tool/build_android.sh /tmp/opencode/indexed-android
```

This builds a universal APK plus split APKs, each with a checksum.

## Notes and limits

- Settings live in `~/.config/fb_viewer/state.json` on Linux and in app-private storage on Android.
- Android media and JSON folders are copied into app-private storage through the system folder picker; the source files are not changed.
- Shared `http(s)` links open in the browser on Android. Local videos and voice clips open in the default player on Linux. HEIC photos cannot be displayed.
- Desktop drag-and-drop and a disk thumbnail cache are not implemented yet.
- Large exports parse in a background isolate with a persistent cache; raw JSON can be dropped to save memory.

Everything runs locally. Indexed does not upload messages, media or settings anywhere.
