# Changelog

## 1.5.1 (unreleased)

- **Faster Android media imports:** SAF folders are enumerated with batched metadata queries and copied concurrently, reducing a 4,000-file import from minutes to seconds.

## 1.5.0

A focused polish pass: faster search, safer media handling, and a quieter reading view on Linux and Android.

- **Folder import (Android):** select a folder of JSON exports; files stream into app-private storage, can be refreshed, and `http(s)` links open in the browser.
- **Media packs:** export only what a chat references, preserving original bytes. Choose re-importable paths or readable date/sender names.
- **Immersive mode:** floating search pill, people filter always available, hidden activity rail, and a position bar during fast scrolling.
- **Faster search:** cached fields, aliases and bookmarks; global search, filters and insights refresh only when data changes.
- **Media folders:** relative paths keep same-named files distinct; missing and duplicate files are reported.
- **Release builds:** Linux tarball, universal and split APKs, each with a SHA-256 checksum. Android APKs are debug-signed for sideloading; uninstall the old app first.
- **Icons and polish:** real Android launcher artwork (including monochrome), a Linux window icon, and Copy JSON confirmation in Message details.
- **Fixes:** reopening JSON revives removed chats, re-picking exports does not duplicate messages, repeated packs keep unique names, and context menus no longer offer `Open conversation`.

## 1.3.0

Android sideload builds, app-private state, SAF media folders, a floating date pill, hideable rails/bars, people filters, and Message details actions.

## 1.2.0

Linux packaging, index-based scrolling, copy/export tools, the Indexed rename, and the `dev.local.indexed` Android identity.
