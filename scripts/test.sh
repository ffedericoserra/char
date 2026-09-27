#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Think.xcodeproj -scheme Think -configuration Debug \
  -derivedDataPath "${THINK_BUILD_DIR:-.build}" -destination 'platform=macOS' test
