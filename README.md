# Messages Viewer

A viewer and organizer for exported Facebook / Messenger messages.

Message exports, especially from end-to-end encrypted chats, arrive as JSON files that are unreadable as they are. Messages Viewer turns them into normal chat threads you can scroll, search and filter, with your photos shown inline. Everything runs on your own device. Nothing is uploaded anywhere.

Built with Flutter. Linux works, Android is next. Capiche?
Made with inspiration from previous projects related to json file viewers(and some other things)

## Features

- Opens one or more exported `.json` files. Files that belong to the same chat (for example `message_1.json`, `message_2.json`) are merged into one conversation.
- Tolerant parser: it looks for message-like data instead of expecting one fixed layout, so it can handle both the regular "Download your information" export and the encrypted-chat export.
- Fixes the garbled accents and emoji that older Facebook exports produce.
- Chat view with date separators, sender names, reactions, unsent-message markers and a configurable "I am" setting that puts your messages on the right.
- Photos shown inline, a full-screen photo viewer (zoom, arrow keys, caption with sender and date) and a gallery grid.
- Photos are matched to messages by the file name written in the JSON. The exported files have random names like `0a9ad60f-e5cc-….jpeg`, so you never need to rename anything.
- Media folders:
  - a **shared** folder that serves every conversation, and/or
  - folders for **one conversation** only (checked first, then the shared ones).
- Media info dialog per conversation: how many files are referenced, how many were found (and in which kind of folder), and the names of the missing ones.
- Search, filtering by sender and "media only".
- Optional search results panel: lists every match, highlights the search words, and jumps to the message in the full conversation when you click a result.
- Large files are parsed in a background isolate, so the window does not freeze.

## Requirements

- Flutter (stable channel)
- For Linux builds: a C/C++ toolchain and GTK 3 development files

## Setup on Fedora

```bash
# Flutter
git clone -b stable https://github.com/flutter/flutter.git ~/development/flutter
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Linux build tools, plus zenity for the file picker dialogs
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel zenity

flutter config --enable-linux-desktop
flutter doctor
```

## Create the project and run it

```bash
flutter create --platforms=linux,android --org dev.local fb_viewer
cd fb_viewer
flutter pub add file_picker scrollable_positioned_list
rm test/widget_test.dart
```

Copy `main.dart`, `models.dart`, `parser.dart`, `settings.dart` and `store.dart` into `fb_viewer/lib/`, replacing the generated `main.dart`. Then:

```bash
flutter run -d linux
```

## How to use

1. Click **Open JSON** and choose your exported file(s).
2. Pick a conversation from the list.
3. Show your photos in one of two ways:
   - **Shared media** (sidebar): choose the folder that holds the exported photos and videos; it applies to every conversation.
   - **Media info** button (chat toolbar): add folders for that conversation only, and see which files are missing.
4. Set **I am** to your name so your messages appear on the right.
5. Use the search box. Turn on the results-panel button if you want a list of matches that jumps to the message in context.
6. Use the gallery button to see all photos in the current filter as a grid.

## Project layout

| File | Purpose |
| --- | --- |
| `lib/main.dart` | User interface: conversation list, chat view, results panel, media dialog, photo viewer |
| `lib/models.dart` | Data classes: messages, media, conversations, media folders |
| `lib/parser.dart` | Tolerant JSON parser, encoding fix, background-isolate helpers |
| `lib/store.dart` | App state: loaded conversations, media folders, lookup, session restore |
| `lib/settings.dart` | User settings and the remembered session, saved to one JSON file |


`fb-messages-viewer.html` is the earlier single-file browser prototype of the same idea.

## Current limitations

- The app remembers which files and folders you opened, not the messages themselves, so a large export is parsed again on every start. A local database (see the roadmap) will fix that.
- Settings and the remembered session are saved to `~/.config/fb_viewer/state.json` (Linux). Android storage for this is not built yet.
- Android folder access is not built yet. The folder picker returns a `content://` handle there, and the app shows a message instead of reading it.
- Videos and voice clips open in the default player on Linux only.
- HEIC photos cannot be displayed.
- Search works inside one conversation at a time.
- Format detection is heuristic. If some text or a sender looks wrong, the export probably uses field names the parser does not know yet. Check the structure of your JSON and extend the key lists at the top of `parser.dart`.

## Troubleshooting

- **File dialogs do not open on Linux:** install `zenity` (`sudo dnf install zenity`).
- **`Member not found: 'platform'` on `FilePicker`:** the code targets `file_picker` 13 and later, which uses static calls such as `FilePicker.pickFiles()`.
- **Photos show "not found in media folders":** open the folder that actually contains those files. Subfolders are searched automatically, and matching ignores capital letters and folder paths.

## Roadmap

1. Android build: folder access, video and audio playback, testing on an Android 17 (AOSP) phone and an Android 14 tablet.
2. Local SQLite database: remember conversations and folders, fast search, quick re-opening of large exports.
3. Settings: theme and other options...
4. Export of the current view to text or CSV, and search across all conversations.

## Privacy

All parsing and viewing happens locally. The app does not send your messages or media anywhere.
