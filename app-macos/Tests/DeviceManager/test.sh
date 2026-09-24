#!/bin/bash
set -euo pipefail
APP_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUTPUT=$(mktemp -d)
trap 'rm -rf "$OUTPUT"' EXIT
xcrun swiftc -swift-version 6 -target arm64-apple-macosx26.0 \
  "$APP_ROOT/Snap-O/Device/Emulators/EmulatorServiceProtocol.swift" \
  "$APP_ROOT/EmulatorService/EmulatorCommand.swift" \
  "$APP_ROOT/EmulatorService/EmulatorConsole.swift" \
  "$APP_ROOT/Tests/DeviceManager/EmulatorConsoleTests.swift" \
  "$APP_ROOT/EmulatorService/EmulatorHost.swift" \
  "$APP_ROOT/Tests/DeviceManager/main.swift" -o "$OUTPUT/tests"
"$OUTPUT/tests"

xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
  "$APP_ROOT/Snap-O/Device/Device.swift" \
  "$APP_ROOT/Snap-O/Models/Device+Formatting.swift" \
  "$APP_ROOT/Snap-O/Device/Emulators/EmulatorServiceProtocol.swift" \
  "$APP_ROOT/Snap-O/DeviceManager/DeviceManagerEntry.swift" \
  "$APP_ROOT/Tests/DeviceManager/DeviceManagerTests.swift" -o "$OUTPUT/device-manager-tests"
"$OUTPUT/device-manager-tests"

xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
  "$APP_ROOT/Snap-O/Device/Device.swift" \
  "$APP_ROOT/Snap-O/Models/Device+Formatting.swift" \
  "$APP_ROOT/Snap-O/Device/Emulators/EmulatorServiceProtocol.swift" \
  "$APP_ROOT/Snap-O/Device/Emulators/EmulatorConnection.swift" \
  "$APP_ROOT/Snap-O/DeviceManager/DeviceManagerEntry.swift" \
  "$APP_ROOT/Snap-O/DeviceManager/DeviceManager.swift" \
  "$APP_ROOT/Tests/Support/TestGate.swift" \
  "$APP_ROOT/Tests/DeviceManager/DeviceInventoryFakes.swift" \
  "$APP_ROOT/Tests/DeviceManager/DeviceInventoryTests.swift" -o "$OUTPUT/device-inventory-tests"
"$OUTPUT/device-inventory-tests" "$@"
