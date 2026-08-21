#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-startup-tests.XXXXXX")
cd "$APP_DIR"

# Compile the production startup code against deterministic device-service doubles.
xcrun swiftc -swift-version 6 -parse-as-library -module-name SnapODeviceClient \
  -emit-module -emit-object SnapODeviceClient/Sources/SnapODeviceClient/Device.swift \
  -emit-module-path "$TEST_DIR/SnapODeviceClient.swiftmodule" -o "$TEST_DIR/Device.o"
xcrun swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" \
  "$TEST_DIR/Device.o" \
  Snap-O/Models/Media.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/Utilities/Perf.swift \
  Snap-O/Capture/PreparedLivePreview.swift Snap-O/Capture/StartupCapturePreparation.swift \
  Snap-O/CaptureWindow/PreparingScreenshotMode.swift Snap-O/CaptureWindow/LivePreviewManager.swift \
  Tests/CaptureSupport/TestSupport.swift Tests/StartupCapture/StartupCaptureTests.swift \
  -o "$TEST_DIR/startup-tests"
"$TEST_DIR/startup-tests"
xcrun swiftc -swift-version 6 -parse-as-library -I "$TEST_DIR" \
  "$TEST_DIR/Device.o" Snap-O/Models/Media.swift Snap-O/LivePreview/LivePreviewSession.swift \
  Tests/StartupCapture/LivePreviewSessionTests.swift -o "$TEST_DIR/session-tests"
"$TEST_DIR/session-tests"
xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/CaptureWindow/LiveCaptureView.swift \
  Tests/StartupCapture/LivePreviewVisibilityTests.swift -o "$TEST_DIR/visibility-tests"
"$TEST_DIR/visibility-tests"
