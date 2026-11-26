#!/usr/bin/env bash
# Build repeatable sideload APKs for Indexed.
# Usage: ./tool/build_android.sh [output-directory]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION_LINE=$(grep -E '^version:[[:space:]]*' pubspec.yaml | head -n 1)
VERSION="${VERSION_LINE#version:}"
VERSION="${VERSION//[[:space:]]/}"
VERSION="${VERSION%%+*}"
if [ -z "$VERSION" ]; then
  echo "Could not read a version from pubspec.yaml" >&2
  exit 1
fi

OUT="${1:-$PWD/build/android/release}"
mkdir -p "$OUT"
rm -f "$OUT"/*.apk "$OUT"/*.sha256
shopt -s nullglob

APK_DIR="build/app/outputs/flutter-apk"

# One universal APK works on every supported device.
flutter build apk --release
if [ ! -f "$APK_DIR/app-release.apk" ]; then
  echo "Expected $APK_DIR/app-release.apk was not produced" >&2
  exit 1
fi
cp "$APK_DIR/app-release.apk" "$OUT/Indexed-universal-$VERSION.apk"

# Smaller per-device APKs for sideloading. All three are promised in releases,
# so a missing ABI is a build failure instead of a silently incomplete upload.
flutter build apk --release --split-per-abi
for abi in arm64-v8a armeabi-v7a x86_64; do
  SRC="$APK_DIR/app-$abi-release.apk"
  if [ ! -f "$SRC" ]; then
    echo "Expected $SRC was not produced" >&2
    exit 1
  fi
  cp "$SRC" "$OUT/Indexed-$abi-$VERSION.apk"
done

# Checksums use bare file names so they can be verified after download.
cd "$OUT"
for f in *.apk; do
  sha256sum "$f" > "$f.sha256"
  echo "$PWD/$f"
  echo "$PWD/$f.sha256"
done
