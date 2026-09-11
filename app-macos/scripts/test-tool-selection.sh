#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-tool-tests.XXXXXX")
SERVER_PID=
trap 'if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

# Use the app's resolved ZIPFoundation dependency for the standalone UI harnesses.
BUILD_DIR=${SNAPO_DERIVED_DATA:-"$TEST_DIR/xcode"}
xcodebuild -quiet -project Snap-O.xcodeproj -scheme Snap-O \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
PRODUCTS="$BUILD_DIR/Build/Products/Debug"
# Xcode may reuse instrumented package objects from a test build.
export LLVM_PROFILE_FILE="$TEST_DIR/%m.profraw"
xcrun swiftc -swift-version 6 -parse-as-library -profile-generate \
  -I "$PRODUCTS" \
  "$PRODUCTS/ZIPFoundation.o" \
  Snap-O/Device/*.swift Snap-O/Device/ADB/*.swift \
  Snap-O/Utilities/Logging.swift \
  Snap-O/Tools/ToolModels.swift \
  Snap-O/Tools/PluginMetadata.swift \
  Tests/ToolSelection/ToolTestFixtures.swift \
  Snap-O/Tools/ToolSelection.swift \
  Snap-O/Tools/AppToolModel.swift \
  Snap-O/CaptureWindow/WorkspaceLayoutController.swift \
  Tests/ToolSelection/WorkspaceLayoutTests.swift \
  Tests/ToolSelection/ToolSelectionTests.swift \
  -o "$TEST_DIR/tool-tests"
"$TEST_DIR/tool-tests"
xcrun swiftc -swift-version 6 -parse-as-library -profile-generate \
  -I "$PRODUCTS" \
  "$PRODUCTS/ZIPFoundation.o" \
  Snap-O/Device/*.swift Snap-O/Device/ADB/*.swift \
  Snap-O/Utilities/Logging.swift \
  Snap-O/Tools/ToolModels.swift \
  Snap-O/Tools/PluginMetadata.swift \
  Tests/ToolSelection/ToolTestFixtures.swift \
  Snap-O/Tools/ToolSelection.swift \
  Snap-O/Tools/AppToolModel.swift \
  Snap-O/Tools/PluginHostModel.swift \
  Snap-O/Models/Media.swift \
  Snap-O/Storage/SaveLocation.swift \
  Snap-O/Tools/ToolWebBridge.swift \
  Snap-O/Tools/ToolWebPolicy.swift \
  Snap-O/Tools/ToolAssetSchemeHandler.swift \
  Snap-O/Tools/ToolWebContainer.swift \
  Snap-O/Tools/ToolWebView.swift \
  Tests/ToolSelection/ToolWebViewTests.swift \
  -o "$TEST_DIR/web-view-tests"
python3 Tests/ToolSelection/Fixtures/security-server.py "$TEST_DIR" &
SERVER_PID=$!
SNAPO_WEB_SECURITY_FIXTURE_DIR="$TEST_DIR" "$TEST_DIR/web-view-tests"
