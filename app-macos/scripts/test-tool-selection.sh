#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$APP_DIR"

# This opt-in integration check launches Snap-O. Workspace layout is covered by the headless target.
xcodebuild -quiet -project Snap-O.xcodeproj -scheme Snap-OIntegrationTests \
  -destination 'platform=macOS' \
  -derivedDataPath "${SNAPO_DERIVED_DATA:-$APP_DIR/.build/tests}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:Snap-OIntegrationTests/ToolSelectionTests \
  -only-testing:Snap-OIntegrationTests/ToolWebPolicyTests \
  -only-testing:Snap-OIntegrationTests/ToolWebContainerTests test
