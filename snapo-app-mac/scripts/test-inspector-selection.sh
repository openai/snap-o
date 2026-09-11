#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-inspector-tests.XXXXXX")
SERVER_PID=
trap 'if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

swift build --package-path SnapODeviceClient --scratch-path "$TEST_DIR/package"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$TEST_DIR/package/debug/Modules" \
  "$TEST_DIR/package/debug/SnapODeviceClient.build/"*.o \
  "$TEST_DIR/package/debug/ZIPFoundation.build/"*.o \
  Snap-O/Inspectors/InspectorModels.swift \
  Snap-O/Inspectors/InspectorMetadata.swift \
  Tests/InspectorSelection/InspectorTestFixtures.swift \
  Snap-O/Inspectors/InspectorSelection.swift \
  Snap-O/Inspectors/AppInspectorModel.swift \
  Snap-O/CaptureWindow/WorkspaceLayoutController.swift \
  Tests/InspectorSelection/WorkspaceLayoutTests.swift \
  Tests/InspectorSelection/InspectorSelectionTests.swift \
  -o "$TEST_DIR/inspector-tests"
"$TEST_DIR/inspector-tests"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$TEST_DIR/package/debug/Modules" \
  "$TEST_DIR/package/debug/SnapODeviceClient.build/"*.o \
  "$TEST_DIR/package/debug/ZIPFoundation.build/"*.o \
  Snap-O/Inspectors/InspectorModels.swift \
  Snap-O/Inspectors/InspectorMetadata.swift \
  Tests/InspectorSelection/InspectorTestFixtures.swift \
  Snap-O/Inspectors/InspectorSelection.swift \
  Snap-O/Inspectors/AppInspectorModel.swift \
  Snap-O/Inspectors/InspectorHostModel.swift \
  Snap-O/Models/Media.swift \
  Snap-O/Storage/SaveLocation.swift \
  Snap-O/Inspectors/InspectorWebBridge.swift \
  Snap-O/Inspectors/InspectorWebPolicy.swift \
  Snap-O/Inspectors/InspectorAssetSchemeHandler.swift \
  Snap-O/Inspectors/InspectorWebContainer.swift \
  Snap-O/Inspectors/InspectorWebView.swift \
  Tests/InspectorSelection/InspectorWebViewTests.swift \
  -o "$TEST_DIR/web-view-tests"
python3 Tests/InspectorSelection/Fixtures/security-server.py "$TEST_DIR" &
SERVER_PID=$!
SNAPO_WEB_SECURITY_FIXTURE_DIR="$TEST_DIR" "$TEST_DIR/web-view-tests"
