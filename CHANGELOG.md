# Changelog

All notable changes to Indexed are documented in this file.

The format is based on Keep a Changelog, and versions follow Semantic Versioning.

## [Unreleased]

Planned next:

- Device validation on the Android 17 AOSP phone.
- Edge-to-edge, back-gesture and touch-layout checks.

### Added

- Immersive conversation mode: a compact search pill with the people-filter eye
  always available, no activity rail, and an overlay position bar that appears
  only during fast scrolling. Toggle it from the chat menu, the compact header,
  or Settings; the choice persists across chats and launches.
- Real Indexed launcher artwork: adaptive Android icons (including monochrome)
  and a bundled Linux window icon.

### Changed

- The left-side activity rail is now off by default on Linux and Android. Older
  state files are migrated off once, then user choices are respected.
- The right-hand position bar is now a rounded overlay pill with no divider and
  no allocated width, so the conversation never resizes around it.
- Android system Back now returns from an open conversation to the chat list,
  leaves dialogs intact, and exits cleanly from the chat list.
- Parse cache files are written incrementally, avoiding a second full copy of
  every message in memory on large exports.
- The long-lived import dedupe index stores compact hashes instead of full
  message text, and only chats that received new messages are re-sorted.
- Stale and interrupted parse cache files are pruned on startup, the media-stat
  cache is bounded, and `.part` / `.tmp` files are ignored by media scanning.

### Fixed

- Overlapping imports still dedupe correctly after the compact index change.
- Only the position bar's pill itself is hit-testable now. Touching the empty
  track no longer jumps immediately or steals Android gesture Back swipes.

## [1.3.0] - 2026-11-26

### Added

- Repeatable Android sideload build script (`tool/build_android.sh`) producing
  a universal APK plus split APKs for `arm64-v8a`, `armeabi-v7a` and `x86_64`,
  each with a SHA-256 checksum.
- `CHANGELOG.md` tracking notable changes.
- A floating date pill in chats shows the date of the messages in the middle of
  the viewport while scrolling (on Linux and Android).
- Optional auto-hide header: scrolling down collapses search into a slim strip
  with a search pill, the people-filter eye and an expand button. The eye is
  always available.
- The right-side position bar can now be hidden from Settings or the chat menu,
  independently of the month activity rail (both Linux and Android).
- Optional "Show time once per minute": in date-sorted chats only the last
  message of a minute shows a time, reducing clutter in busy conversations.

### Changed

- Temporary media folders, test fixtures and generated export filenames now use
  `indexed_` prefixes instead of `fb_viewer_`. Package and config names stay
  `fb_viewer` for compatibility.
- Android now stores settings, imported JSON and media folders in app-private
  storage instead of `$HOME/.config` and temporary directories.
- Android media selection uses the system folder picker again. A native SAF
  bridge streams photos and videos into app storage so large mixed folders can
  be indexed without gallery multi-select. The import now shows file-by-file
  progress and can be cancelled.
- Android folder imports list files first, use a larger buffer and avoid extra
  provider queries per file. Re-picking an unchanged folder no longer rescans
  the whole chat's media references.
- People filters now open in their own dialog instead of pushing the search bar
  down. The eye icon opens the dialog from either the full or collapsed header.
- Copy and bookmark actions moved from every message bubble into Message
  details (right-click / long-press / click the time). Consecutive messages from
  the same sender now use tighter vertical spacing.

### Fixed

- Settings, saved session and opened JSON files no longer disappear after the
  Android app is closed or killed in the background.
- `state.json` is now written synchronously on lifecycle pauses, so a fast app
  switch cannot lose the last settings change.
- The Android media button no longer opens a photo picker or rejects `content://`
  folder handles; picked folders are imported and persisted across restarts.
- Android folder imports no longer leave truncated files behind when interrupted,
  mix up names that sanitize to the same value, or abort everything because one
  document was unreadable.
- Long-pressing a message on Android now opens Message details, matching
  right-click on Linux. Hidden-by-grouping timestamps no longer leave stray
  info icons under earlier messages.

## [1.2.0] - 2026-11-26

### Added

- Automated Linux release workflow triggered by `v*` tags, attaching the
  release tarball and SHA-256 checksum.
- Local packaging script `tool/package_linux.sh`, which archives the whole
  release bundle with the required trailing `.`.
- Index-based right-side scrollbar for large conversations, avoiding pixel
  layout of tens of thousands of variable-height bubbles.
- Explicit **Copy text** action on messages and in Message details.
- Export-dialog warning when **Original JSON** is requested but raw data was
  not kept in memory.
- Release workflow check that the pushed tag matches `pubspec.yaml`.
- Synchronous breadcrumbs in `error.log` for startup, imports, conversation
  opens, global search, tools and Insights analysis.

### Changed

- Display name is now **Indexed** across Linux and Android.
- Android namespace, applicationId and Kotlin package renamed to
  `dev.local.indexed`; the Dart package and config folder remain `fb_viewer`
  so existing data keeps working.
- Activity rail scrubbing now uses lightweight index jumps during drag and one
  full jump on release.
- The index scrollbar thumb follows the pointer locally, throttles list jumps
  and stays in place until the list catches up.
- Bubble text uses plain `Text` / `Text.rich` instead of `SelectableText` to
  make jumps cheaper; selectable text remains available in Message details.
- "Where I left off" now works in both oldest-first and newest-first date sorts.
- Scrollbar and rail indicators update under all sort modes; saved reading
  positions remain limited to date-sorted views.
- Large-export warning threshold lowered to 8 MB.
- Image cache reduced to 160 MB / 1200 images.
- Parse cache, global search limit/truncation and Insights analysis hardened.
- UI spacing pass: cleaner scrollbars, padding, rounded selected tiles and
  more breathing room around bubbles and rows.
- README updated for release packaging and early Android support.

### Fixed

- Native pixel scrollbar no longer freezes large chats or forces mass layout
  of all previous variable-height bubbles.
- Scrollbar thumb no longer snaps back before the final jump lands.
- Scrollbar and activity-rail positions no longer freeze in non-date sort modes.
- Initial thumb position corrected for newest-first / reversed conversations.
- Activity-rail drag no longer rebuilds toolbars or restarts the highlight
  timer on every pointer event.
- Release archives, checksums and Android APK/AAB outputs are excluded from Git.
