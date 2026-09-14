#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$APP_DIR"

# CI runs these with the full native suite; this is the focused local entry point.
xcodebuild -quiet -project Snap-O.xcodeproj -scheme Snap-O \
  -destination 'platform=macOS' \
  -derivedDataPath "${SNAPO_DERIVED_DATA:-$APP_DIR/.build/tests}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:Snap-OTests/ToolSelectionTests \
  -only-testing:Snap-OTests/WorkspaceLayoutTests \
  -only-testing:Snap-OTests/ToolWebPolicyTests \
  -only-testing:Snap-OTests/ToolWebContainerTests test
