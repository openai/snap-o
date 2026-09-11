#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-inspector-recovery.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library -whole-module-optimization \
  -module-name SnapODeviceClient -emit-module -emit-object \
  SnapODeviceClient/Sources/SnapODeviceClient/Device.swift \
  SnapODeviceClient/Sources/SnapODeviceClient/InspectorServerReference.swift \
  SnapODeviceClient/Sources/SnapODeviceClient/InspectorDiscovery.swift \
  SnapODeviceClient/Sources/SnapODeviceClient/DeviceDiscovery.swift \
  Tests/InspectorRecovery/DeviceClientDouble.swift \
  -emit-module-path "$TEST_DIR/SnapODeviceClient.swiftmodule" -o "$TEST_DIR/DeviceClient.o"
xcrun swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" \
  "$TEST_DIR/DeviceClient.o" Snap-O/Models/Device+Formatting.swift \
  Snap-O/ADB/DeviceTracker.swift \
  Snap-O/Inspectors/InspectorModels.swift \
  Snap-O/Inspectors/InspectorPluginRegistry.swift \
  Tests/InspectorSelection/InspectorTestPlugins.swift \
  Snap-O/Inspectors/InspectorSelection.swift \
  Snap-O/Inspectors/AppInspectorModel.swift \
  Snap-O/Inspectors/InspectorHTTPService.swift \
  Snap-O/Inspectors/InspectorService.swift \
  Tests/InspectorRecovery/InspectorRecoveryTests.swift -o "$TEST_DIR/inspector-recovery-tests"
"$TEST_DIR/inspector-recovery-tests"
