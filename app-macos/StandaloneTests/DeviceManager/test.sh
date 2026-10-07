#!/bin/bash
set -euo pipefail
APP_DIR=$(cd "$(dirname "$0")/../.." && pwd)
OUTPUT=$(mktemp -d)
trap 'rm -rf "$OUTPUT"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift.sh"
swiftc_for_tests -swift-version 6 -target arm64-apple-macosx26.0 \
  "$APP_DIR/Snap-O/Device/AndroidHostServiceProtocol.swift" \
  "$APP_DIR/AndroidHostService/EmulatorCommand.swift" \
  "$APP_DIR/AndroidHostService/ADBServer.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/ADBServerTests.swift" \
  "$APP_DIR/AndroidHostService/EmulatorConsole.swift" \
  "$APP_DIR/AndroidHostService/EmulatorSocketOwner.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/EmulatorSocketOwnerTests.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/EmulatorConsoleTests.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/EmulatorDisplayTests.swift" \
  "$APP_DIR/AndroidHostService/EmulatorHost.swift" \
  "$APP_DIR/AndroidHostService/EmulatorDisplayReader.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/main.swift" -o "$OUTPUT/tests"
run_test "$OUTPUT/tests"

swiftc_for_tests -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
  "$APP_DIR/Snap-O/Device/ADBServerState.swift" \
  "$APP_DIR/Snap-O/Device/Device.swift" \
  "$APP_DIR/Snap-O/Device/DeviceTracking.swift" \
  "$APP_DIR/Snap-O/Device/ADB/ADBConnection.swift" \
  "$APP_DIR/Snap-O/Models/Device+Formatting.swift" \
  "$APP_DIR/Snap-O/Device/AndroidHostServiceProtocol.swift" \
  "$APP_DIR/Snap-O/Device/Emulators/EmulatorConnection.swift" \
  "$APP_DIR/Snap-O/DeviceManager/DeviceManagerEntry.swift" \
  "$APP_DIR/Snap-O/DeviceManager/DeviceManager.swift" \
  "$APP_DIR/Snap-O/DeviceManager/DeviceOpenResolver.swift" \
  "$APP_DIR/Snap-O/Models/DeviceOpenRequest.swift" \
  "$APP_DIR/Snap-OIntegrationTests/AsyncTestSupport.swift" \
  "$APP_DIR/StandaloneTests/Support/TestGate.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/DeviceInventoryFakes.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/DeviceManagerTests.swift" \
  "$APP_DIR/StandaloneTests/DeviceManager/DeviceInventoryTests.swift" -o "$OUTPUT/device-inventory-tests"
run_test "$OUTPUT/device-inventory-tests" "$@"

bash "$APP_DIR/StandaloneTests/AndroidHostSecurity/test.sh"
