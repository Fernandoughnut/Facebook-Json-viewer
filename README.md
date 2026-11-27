# Indexed

[![Flutter checks](https://github.com/Fernandoughnut/Indexed/actions/workflows/flutter.yml/badge.svg)](https://github.com/Fernandoughnut/Indexed/actions/workflows/flutter.yml)
[![Latest release](https://img.shields.io/github/v/release/Fernandoughnut/Indexed)](https://github.com/Fernandoughnut/Indexed/releases/latest)

A local viewer for Facebook / Messenger JSON exports. Read conversations, search and filter them, show the original media inline, and export what you need.

**Everything runs on your device. Nothing is uploaded.**

Available for **Linux** and **Android** (sideloaded APKs).

## Contents

- [Quick start](#quick-start)
- [Getting your Facebook export](#getting-your-facebook-export)
- [Features](#features)
- [Downloads](#downloads)
- [Build from source](#build-from-source)
- [Notes and limitations](#notes-and-limitations)
- [Privacy](#privacy)

## Quick start

1. Download the Linux bundle or an Android APK from the [latest release](https://github.com/Fernandoughnut/Indexed/releases/latest).
2. Open one or more `.json` exports with **Open JSON**, or use **Import folder** to load every `.json` file in a folder.
3. Set **I am** to your name and add your media folder(s) so photos and videos show up inline.
4. Search, filter, export, or pack a conversation's media.

Removing a conversation only hides it locally. Opening its JSON again restores it, and re-picking the same export does not duplicate messages.

## Getting your Facebook export

Indexed reads the JSON files from Facebook's "Download your information" tool. When you request the download, choose **JSON** as the format (not HTML) and include your messages. Menu names change over time, so look for "Download your information" in your Facebook or Accounts Center settings.

Once the download finishes, unzip it. The conversation `.json` files are inside the messages folders, and the photos and videos are in the matching media folders.

## Features

- **Chat view:** dates, reactions, replies, bookmarks, notes, three layouts, and a saved reading position.
- **Search:** by text, sender, or media type, with regex and case options, people filters, and saved searches.
- **Tools:** insights, links, duplicate and missing-media checks, and JSON / CSV / text export.
- **Media:** inline photos, a gallery, a full-screen viewer, and byte-preserving media packs.
- **Appearance and access:** Material 3 or Classic themes, optional immersive reading, and a local PIN gate (a convenience lock, not encryption).

## Downloads

Each release includes:

| Asset | Notes |
|---|---|
| `Indexed-linux-x64-vX.Y.Z.tar.gz` | Extract and run `./indexed`. |
| `Indexed-universal-X.Y.Z.apk` | Works on any supported Android device. |
| Split APKs | `arm64-v8a`, `armeabi-v7a`, and `x86_64`. |
| `.sha256` files | One checksum per asset. |

Android APKs are debug-signed with the application ID `dev.local.indexed`. Uninstall any older Indexed or `dev.local.fb_viewer` APK before installing.

## Build from source

You need the Flutter stable SDK. Linux builds also need a C/C++ toolchain and GTK 3 development files.

```bash
flutter pub get
flutter analyze
flutter test
```

Package the Linux build:

```bash
./tool/package_linux.sh Indexed-linux-x64.tar.gz
```

The executable is `build/linux/x64/release/bundle/indexed`. Keep the whole `bundle` folder together.

Build the Android APKs:

```bash
./tool/build_android.sh [output-directory]
```

This produces a universal APK plus split APKs, each with a checksum. Without an argument, output goes to `build/android/release`.

`tool/generate_large_export.dart` creates a large synthetic export, which is useful for testing performance.

## Notes and limitations

- Settings live in `~/.config/fb_viewer/state.json` on Linux and in app-private storage on Android. The `fb_viewer` name is from the app's earlier name, before it became Indexed.
- Android folder imports are copied into app-private storage. Your source files are not changed.
- HEIC photos cannot be displayed.
- Desktop drag-and-drop and a thumbnail cache are not implemented yet.
- Large exports are parsed in a background isolate with a persistent cache. Raw JSON can be dropped from memory to save RAM.

See the [changelog](CHANGELOG.md) for release history.

## Privacy

Indexed does not upload messages, media, or settings anywhere. Everything stays on your device.
