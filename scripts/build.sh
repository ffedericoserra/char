#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Think.xcodeproj -scheme Think -configuration Release \
  -derivedDataPath "${THINK_BUILD_DIR:-.build}" build
mkdir -p build
staging_dir="$(mktemp -d "$(pwd)/build/.Think-build.XXXXXX")"
ditto "${THINK_BUILD_DIR:-.build}/Build/Products/Release/Think.app" "$staging_dir/Think.app"
if [ -d build/Think.app ]; then
  # Keep the executable of an already-running instance intact until it quits.
  previous_dir="$(mktemp -d "$(pwd)/build/.Think-previous.XXXXXX")"
  mv build/Think.app "$previous_dir/Think.app"
fi
mv "$staging_dir/Think.app" build/Think.app
rmdir "$staging_dir"
echo "Built: $(pwd)/build/Think.app"
