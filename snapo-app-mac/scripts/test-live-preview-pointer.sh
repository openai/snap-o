#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-pointer-tests.XXXXXX")
cd "$APP_DIR"

# Exercise the production sender and rotation lifecycle without injecting device input.
xcrun swiftc -swift-version 6 -parse-as-library -module-name SnapODeviceClient \
  -emit-module -emit-object Tests/LivePreviewPointer/DeviceClientDouble.swift \
  -emit-module-path "$TEST_DIR/SnapODeviceClient.swiftmodule" -o "$TEST_DIR/DeviceClient.o"
xcrun swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" \
  "$TEST_DIR/DeviceClient.o" Snap-O/Utilities/Logging.swift \
  Snap-O/LivePreview/LivePreviewPointerBackend.swift \
  Snap-O/LivePreview/LivePreviewPointerInjector.swift \
  Snap-O/LivePreview/UInputLivePreviewPointerBackend.swift \
  Tests/LivePreviewPointer/LivePreviewPointerTests.swift -o "$TEST_DIR/pointer-tests"
"$TEST_DIR/pointer-tests"
