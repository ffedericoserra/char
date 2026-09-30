#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project char.xcodeproj -scheme char -configuration Release \
  -derivedDataPath "${CHAR_BUILD_DIR:-.build}" build
mkdir -p build
staging_dir="$(mktemp -d "$(pwd)/build/.char-build.XXXXXX")"
ditto "${CHAR_BUILD_DIR:-.build}/Build/Products/Release/char.app" "$staging_dir/char.app"
if [ -d build/char.app ]; then
  # Keep the executable of an already-running instance intact until it quits.
  previous_dir="$(mktemp -d "$(pwd)/build/.char-previous.XXXXXX")"
  mv build/char.app "$previous_dir/char.app"
fi
mv "$staging_dir/char.app" build/char.app
rmdir "$staging_dir"
echo "Built: $(pwd)/build/char.app"
