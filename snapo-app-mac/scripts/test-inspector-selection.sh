#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-inspector-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

swift build --package-path SnapODeviceClient --scratch-path "$TEST_DIR/package"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$TEST_DIR/package/debug/Modules" \
  "$TEST_DIR/package/debug/SnapODeviceClient.build/"*.o \
  Snap-O/Inspectors/InspectorModels.swift \
  Snap-O/Inspectors/InspectorPluginRegistry.swift \
  Tests/InspectorSelection/InspectorTestPlugins.swift \
  Snap-O/Inspectors/InspectorSelection.swift \
  Snap-O/Inspectors/AppInspectorModel.swift \
  Tests/InspectorSelection/InspectorSelectionTests.swift \
  -o "$TEST_DIR/inspector-tests"
"$TEST_DIR/inspector-tests"
xcrun swiftc -swift-version 6 -parse-as-library \
  -I "$TEST_DIR/package/debug/Modules" \
  "$TEST_DIR/package/debug/SnapODeviceClient.build/"*.o \
  Snap-O/Inspectors/InspectorModels.swift \
  Snap-O/Inspectors/InspectorPluginRegistry.swift \
  Tests/InspectorSelection/InspectorTestPlugins.swift \
  Snap-O/Inspectors/InspectorSelection.swift \
  Snap-O/Inspectors/AppInspectorModel.swift \
  Snap-O/Inspectors/InspectorHostModel.swift \
  Snap-O/Models/Media.swift \
  Snap-O/Storage/SaveLocation.swift \
  Snap-O/Inspectors/InspectorWebBridge.swift \
  Snap-O/Inspectors/InspectorWebContainer.swift \
  Snap-O/Inspectors/InspectorWebView.swift \
  Tests/InspectorSelection/InspectorWebViewTests.swift \
  -o "$TEST_DIR/web-view-tests"
"$TEST_DIR/web-view-tests"
