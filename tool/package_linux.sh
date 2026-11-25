#!/usr/bin/env bash
# Build and package the whole Linux bundle, not just the executable.
# Usage: ./tool/package_linux.sh [archive-name.tar.gz]
set -euo pipefail

cd "$(dirname "$0")/.."

flutter build linux --release

ARCHIVE="${1:-indexed-linux-x64.tar.gz}"
case "$ARCHIVE" in
  /*) ;;
  *) ARCHIVE="$PWD/$ARCHIVE" ;;
esac

rm -f "$ARCHIVE" "$ARCHIVE.sha256"
# The trailing '.' is essential: the archive must contain the bundle's contents,
# not a top-level 'bundle' directory.
tar -czf "$ARCHIVE" -C build/linux/x64/release/bundle .
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

echo "$ARCHIVE"
echo "$ARCHIVE.sha256"
