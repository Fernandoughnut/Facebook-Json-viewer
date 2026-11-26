# Changelog

## 1.5.0 (unreleased)

A major refinement pass across Linux and Android. Themes, media, navigation and
large-conversation performance were tightened, and Android gained complete
folder JSON import plus link handling.

### Added

- Conversation media packs: bundle only the files a chat references, with
  byte-for-byte originals, a manifest, and a choice of re-importable original
  paths or readable `date_sender_name` names. Android writes archives through a
  native SAF stream, so large packs never cross the method channel in memory.
- Immersive reading mode: a floating translucent search pill, the people-filter
  eye always available, no activity rail, and a position bar that appears only
  during sustained fast scrolling.
- Real Indexed launcher artwork for Android (including monochrome) and a Linux
  window icon.
- Android SAF folder import for exported `.json` files, with refresh on
  re-picking, and `http(s)` links from messages opening in the browser.
- Copy JSON in Message details now confirms on screen.

### Changed

- The activity rail is off by default on Linux and Android; existing settings
  are migrated once. The position bar is a narrow overlay pill that does not
  resize the conversation or block Android edge gestures.
- Global search, in-chat filtering and the bookmark tools refresh only when the
  underlying data changes. Search fields and aliases are lower-cased lazily and
  cached, and the long-lived dedupe index stores compact hashes.
- Media folders index relative paths as well as file names, so identical
  basenames in different folders stay distinct. Duplicate references and files
  that vanished after indexing are reported explicitly.
- Parse caches are written incrementally and pruned on startup; interrupted
  `.part` / `.tmp` files are ignored.
- Android imports stream SAF documents into app-private storage, show progress,
  can be cancelled, and detect edits by size and modification time. Settings
  are written synchronously at lifecycle pauses.
- Release builds ship a Linux bundle plus a universal APK, split APKs, and a
  SHA-256 checksum for every asset. The debug-signed identity is for sideloading
  only; uninstall an older Indexed APK before updating.

### Fixed

- Explicitly reopening a JSON revives a removed conversation; startup restore
  still skips removed chats. Re-picking a shared export no longer duplicates
  messages.
- Alias changes rebuild in-place filtered chat views. Bookmark caches are
  invalidated when chats or all data are removed.
- Repeated media packs no longer collapse same-named files or overwrite an
  archive created in the same second.
- The immersive overlay no longer closes on scroll, and its controls no longer
  reserve header space.
- Conversation context menus no longer offer `Open conversation`; copy and
  bookmark actions live only in Message details.
- Android folder imports no longer leave truncated files, merge sanitized
  names, or flatten nested JSON files on import.

## 1.3.0

Android sideload builds, app-private state, SAF media folders, a floating date
pill, hideable rails/bars, people-filter dialog, Message details actions, and
tighter reading layouts.

## 1.2.0

Linux release packaging and tag checks, index-based scrolling, explicit copy
text, export warnings, breadcrumbs, the Indexed rename and `dev.local.indexed`
Android identity.
