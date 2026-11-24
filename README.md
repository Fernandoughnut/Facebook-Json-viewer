# Messages Viewer

A viewer and organizer for exported Facebook / Messenger messages.

Message exports, especially from end-to-end encrypted chats, arrive as JSON files that are unreadable as they are. Messages Viewer turns them into normal chat threads you can scroll, search, filter and export, with your photos shown inline. Everything runs on your own device. Nothing is uploaded anywhere.

Built with Flutter. Linux works today; Android builds should work with the file-picker fallbacks described below, but have not been tested on a device.
Should work easily on android

## Features

### Reading and navigation

- Opens one or more exported `.json` files at once, or every `.json` file in a folder. Files that belong to the same chat (for example `message_1.json`, `message_2.json`) are merged into one conversation.
- Tolerant parser: it looks for message-like data instead of expecting one fixed layout, so it can handle both the regular "Download your information" export and the encrypted-chat export.
- Fixes the garbled accents and emoji that older Facebook exports produce.
- Chat view with date separators, sender names, reactions, unsent-message markers and a configurable "I am" setting that puts your messages on the right.
- Three message layouts: **Bubbles**, **Compact**, and **Plain log** (one line per message, like a chat log).
- Choose where a conversation opens: at the **newest** message, the **oldest** message, or **where you left off**.
- Sort messages by date (either direction), sender, longest messages, most reactions, messages with media, or **grouped threads**.
- **Jump to date** picks a day and scrolls straight to it.
- Replies: a message that replies to another shows a quoted block ("Replying to …"); click it to jump to the original. A bookmark-shaped reply icon also shows **all replies to a message** and lets you jump to one.
- "Message details": right-click a message (or click its time) to see the original JSON, reply info, and its note.
- Optional bookmarks and notes per message. Notes are searchable from the **Tools → Saved** tab.
- `Ctrl+F` jumps to the search box; `Ctrl/⌘ K` opens the command palette, and `?` shows the shortcut sheet.
- The command palette searches every action and open conversation, so advanced features do not need permanent toolbar buttons.

### Search and analysis

- Search, filtering by sender and "media only", plus **regex** and **case-sensitive** modes. Search, view, sort and export controls are grouped into one toolbar menu; only active filters appear as removable chips.
- **Saved searches** store a named combination of query, sender, media-only, regex/case-sensitive and sort mode. Apply, save or delete them from `Search → Saved searches…`; the active preset appears as a chip.
- Optional search results panel: lists every match, highlights the search words, and jumps to the message in the full conversation when you click a result. Detailed or compact layout, newest or oldest first.
- The **activity rail** is a thin vertical density bar beside the chat. Click or drag it to jump by month; it can be hidden in the chat menu or Settings.
- **Search every conversation** from the sidebar (global search), with sender/media filters and jump-to-message.
- **Tools** screen with four tabs:
  - **Saved** — bookmarks and notes.
  - **Insights** — messages per person/year, reactions, media, links, replies, typical reply time, longest quiet gaps, and most-used words by person.
  - **Links** — every shared URL, with context, copy and CSV export.
  - **Media** — coverage per conversation, missing-file CSV, duplicate detection by streamed SHA-256, and "copy with readable names" (`YYYY-MM-DD_Sender_originalname`). Scanning and copying run in a background isolate.

### Media

- Photos shown inline, a full-screen photo viewer (zoom, arrow keys, caption with sender and date) and a gallery grid.
- Photos are matched to messages by the file name written in the JSON. The exported files have random names like `0a9ad60f-e5cc-….jpeg`, so you never need to rename anything.
- Media folders: a **shared** folder that serves every conversation, and/or folders for **one conversation** only (checked first, then the shared ones).
- Media info dialog per conversation: how many files are referenced, how many were found (and in which kind of folder), and the names of the missing ones.
- On Android, where a folder pick returns a `content://` handle, the app falls back to selecting the media files and copies them into a temporary folder for the current session.

### Export and performance

- Export the whole conversation, the current filtered view, or a multi-selected set of messages from the chat toolbar. One dialog chooses scope, format (JSON / CSV / text) and what to include: original JSON, media, reactions and display names.
- Clean JSON export (`messages-viewer/1`) omits duplicate raw fields by default; raw data, media and reactions can be included if wanted. CSV always includes media and reactions.
- Participant aliases change only what you see and export; the original names in the exported JSON are untouched.
- Overlapping exports are deduplicated by message ID, or by time + sender + text + media when no ID exists.
- Large files are parsed in a background isolate, so the window does not freeze, and a progress bar shows while files or folders are being read.
- **Persistent parse cache**: the first launch parses an export, later launches read a normalized cache keyed by file path, size and modified time. Can be cleared or disabled in Settings.
- **Optional raw retention**: turn off "Keep original JSON in memory" to save a lot of RAM on huge exports (raw JSON will no longer appear in Message details or exports).
- Sliders commit once on release, and theme changes only rebuild the root theme widget, so large conversations do not stutter.
- Theme animation is optional (`Settings → Appearance → Animate theme changes`); it is off by default.
- Remembers your session: the next time you start, the same JSON files, shared media folders, per-conversation folders, your "I am" name and the last open conversation come back automatically (can be turned off).
- Errors are written to `~/.config/fb_viewer/error.log`, and can be read/cleared from Settings.

### Settings and privacy

- Light / dark / system theme, pure-black (AMOLED) dark mode, accent color, text size, start position, message layout, reply display, 12- or 24-hour clock, message times, photo width in chat, gallery tile size, search results layout and activity rail.
- Settings has a search box and collapsible sections, so you can jump straight to theme, cache, PIN, media or session options.
- Optional local PIN gate on start, stored as a salted SHA-256 hash. It is a convenience lock for a shared device, **not** encryption of your data.
- "Forgot PIN? Reset local lock" (with confirmation) removes the gate if the PIN is lost. Settings are also flushed when the app is backgrounded or closed.

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

## Build and run

```bash
cd fb_viewer
flutter pub get
flutter analyze
flutter test
flutter run -d linux
```

To measure parsing on a synthetic 100k-message export:

```bash
dart run tool/generate_large_export.dart 100000 /tmp/opencode/large_export.json
```

## How to use

1. Click **Open JSON** and choose one or more exported files, or use the folder button to import every `.json` file under a folder.
2. Pick a conversation from the list.
3. Show your photos in one of two ways:
   - **Shared media** (sidebar): choose the folder that holds the exported photos and videos; it applies to every conversation.
   - **Media info** button (chat toolbar): add folders for that conversation only, and see which files are missing.
4. Set **I am** to your name so your messages appear on the right.
5. Use the search box. Turn on the results-panel button if you want a list of matches that jumps to the message in context. Use the magnifying-glass-with-compass button in the sidebar to search all conversations.
6. Use the **Tools** button for bookmarks, notes, insights, links and media cleanup.
7. Use the download button in the chat toolbar to export the whole conversation, the current view, or the current selection.
8. Use the gallery button to see all photos in the current filter as a grid.

## Project layout

| File | Purpose |
| --- | --- |
| `lib/main.dart` | App start, PIN gate, theme, conversation list |
| `lib/chat_view.dart` | One open conversation: search, sorting, threads, results panel, gallery, jumps, export |
| `lib/widgets.dart` | Message bubbles, reply quotes, message details, media info dialog, photo viewer |
| `lib/settings_screen.dart` | The settings screen |
| `lib/settings.dart` | User settings, cached themes, remembered session, PIN hash |
| `lib/models.dart` | Data classes: messages, replies, media, conversations, media folders |
| `lib/parser.dart` | Tolerant JSON parser, encoding fix, normalize/cache format, background-isolate helpers |
| `lib/store.dart` | App state: conversations, dedupe, reply links, global search, media lookup, duplicate detection |
| `lib/util.dart` | Shared helpers: dates, search matching, folder picker, Android media fallback |
| `lib/exporter.dart` | JSON / CSV / text export and clean export schema |
| `lib/global_search_screen.dart` | Cross-conversation search screen |
| `lib/tools_screen.dart` | Bookmarks, insights, links and media tools |
| `test/` | Parser, cache, export and sample-export regression tests |
| `tool/` | Synthetic large-export generator and benchmark |

## Current limitations

- Settings and the remembered session are saved to `~/.config/fb_viewer/state.json` on Linux. Android storage for this has not been tested yet.
- Android media access works by selecting files (copied to a temporary folder), not by walking an entire `content://` tree.
- Videos and voice clips open in the default player on Linux only.
- HEIC photos cannot be displayed.
- Desktop drag-and-drop of files onto the window is not implemented; use **Open JSON** or the folder-import button. Bulk import and multi-file selection are supported.
- Very large photo collections are decoded at reduced size and cached in memory, but there is no disk thumbnail cache yet.
- Reply display depends on the export. The parser looks for common field names (`reply_to`, `replyTo`, `quoted_message`, …) and for message IDs. If replies do not show, open "Message details" and look at its fields; the field names there tell us what to add to `replyKeys` in `parser.dart`.
- Format detection is heuristic. If some text or a sender looks wrong, the export probably uses field names the parser does not know yet. Check the structure of your JSON and extend the key lists at the top of `parser.dart`.
- The PIN gate is not encryption. Anyone with access to the JSON files can still read them directly; the gate can be removed from the lock screen or Settings with confirmation.

## Troubleshooting

- **File dialogs do not open on Linux:** install `zenity` (`sudo dnf install zenity`).
- **`Member not found: 'platform'` on `FilePicker`:** the code targets `file_picker` 13 and later, which uses static calls such as `FilePicker.pickFiles()`.
- **Photos show "not found in media folders":** open the folder that actually contains those files. Subfolders are searched automatically, and matching ignores capital letters and folder paths.
- **A changed export still shows old messages:** the parse cache keys on file size and modified time; use **Settings → Clear parse cache** if a file was replaced in a way that kept both unchanged.

## Roadmap

1. Device-test Android: video/audio playback and persistent SAF folder permissions.
2. Disk thumbnail cache for large photo collections.
3. Desktop drag-and-drop import (needs a platform plugin).
4. Optional native biometric unlock (needs `local_auth` and device testing).
5. More export presets and schema versions.

## Privacy

All parsing, searching, analysis and exporting happens locally. The app does not send your messages or media anywhere.
