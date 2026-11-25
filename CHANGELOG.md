# Changelog

All notable changes to Indexed are documented in this file.

The format is based on Keep a Changelog, and versions follow Semantic Versioning.

## [Unreleased]

### Added

- Repeatable Android sideload build script (`tool/build_android.sh`) producing
  a universal APK plus split APKs for `arm64-v8a`, `armeabi-v7a` and `x86_64`,
  each with a SHA-256 checksum.
- `CHANGELOG.md` tracking notable changes.

### Changed

- Temporary media folders, test fixtures and generated export filenames now use
  `indexed_` prefixes instead of `fb_viewer_`. Package and config names stay
  `fb_viewer` for compatibility.
- Android now stores settings, imported JSON and media folders in app-private
  storage instead of `$HOME/.config` and temporary directories.
- Android media selection uses the system folder picker again. A native SAF
  bridge streams photos and videos into app storage so large mixed folders can
  be indexed without gallery multi-select.

### Fixed

- Settings, saved session and opened JSON files no longer disappear after the
  Android app is closed or killed in the background.
- `state.json` is now written synchronously on lifecycle pauses, so a fast app
  switch cannot lose the last settings change.
- The Android media button no longer opens a photo picker or rejects `content://`
  folder handles; picked folders are imported and persisted across restarts.

Planned next:

- Device validation on the Android 17 AOSP phone and Android 14 tablet.
- Edge-to-edge, back-gesture and touch-layout checks.
- Replace the placeholder launcher icon with the new Indexed artwork.

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
