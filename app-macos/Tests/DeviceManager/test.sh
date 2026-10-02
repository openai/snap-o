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
  "$APP_DIR/Tests/DeviceManager/ADBServerTests.swift" \
  "$APP_DIR/AndroidHostService/EmulatorConsole.swift" \
  "$APP_DIR/Tests/DeviceManager/EmulatorConsoleTests.swift" \
  "$APP_DIR/AndroidHostService/EmulatorHost.swift" \
  "$APP_DIR/Tests/DeviceManager/main.swift" -o "$OUTPUT/tests"
run_test "$OUTPUT/tests"

swiftc_for_tests -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
  "$APP_DIR/Snap-O/Device/Device.swift" \
  "$APP_DIR/Snap-O/Models/Device+Formatting.swift" \
  "$APP_DIR/Snap-O/Device/AndroidHostServiceProtocol.swift" \
  "$APP_DIR/Snap-O/Device/Emulators/EmulatorConnection.swift" \
  "$APP_DIR/Snap-O/DeviceManager/DeviceManagerEntry.swift" \
  "$APP_DIR/Snap-O/DeviceManager/DeviceManager.swift" \
  "$APP_DIR/Snap-OTests/AsyncTestSupport.swift" \
  "$APP_DIR/Tests/Support/TestGate.swift" \
  "$APP_DIR/Tests/DeviceManager/DeviceInventoryFakes.swift" \
  "$APP_DIR/Tests/DeviceManager/DeviceManagerTests.swift" \
  "$APP_DIR/Tests/DeviceManager/DeviceInventoryTests.swift" -o "$OUTPUT/device-inventory-tests"
run_test "$OUTPUT/device-inventory-tests" "$@"
