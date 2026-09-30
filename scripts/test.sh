#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project char.xcodeproj -scheme char -configuration Debug \
  -derivedDataPath "${CHAR_BUILD_DIR:-.build}" -destination 'platform=macOS' test
