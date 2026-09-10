#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-inspector-recovery.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library -whole-module-optimization \
  -module-name SnapODeviceClient -emit-module -emit-object \
  SnapODeviceClient/Sources/SnapODeviceClient/Device.swift \
  SnapODeviceClient/Sources/SnapODeviceClient/NetworkProtocol.swift \
  SnapODeviceClient/Sources/SnapODeviceClient/InspectorDiscovery.swift \
  SnapODeviceClient/Sources/SnapODeviceClient/NetworkServerDiscovery.swift \
  Tests/InspectorRecovery/DeviceClientDouble.swift \
  -emit-module-path "$TEST_DIR/SnapODeviceClient.swiftmodule" -o "$TEST_DIR/DeviceClient.o"
xcrun swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" \
  "$TEST_DIR/DeviceClient.o" Snap-O/Models/Device+Formatting.swift \
  Snap-O/ADB/DeviceTracker.swift \
  Snap-O/NetworkInspector/NetworkInspectorBridgeModels.swift \
  Snap-O/NetworkInspector/InspectorSelection.swift \
  Snap-O/NetworkInspector/AppInspectorModel.swift \
  Snap-O/NetworkInspector/TweakEventStreamDecoder.swift \
  Snap-O/NetworkInspector/TweaksInspectorService.swift \
  Snap-O/NetworkInspector/NetworkInspectorService.swift \
  Tests/InspectorRecovery/InspectorRecoveryTests.swift -o "$TEST_DIR/inspector-recovery-tests"
"$TEST_DIR/inspector-recovery-tests"
