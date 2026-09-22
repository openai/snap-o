#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-startup-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

# Compile the production startup code against deterministic device-service doubles.
xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift \
  Snap-O/Models/Media.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/Utilities/Perf.swift \
  Snap-O/Capture/PreparedLivePreview.swift Snap-O/Capture/StartupCapturePreparation.swift \
  Snap-O/CaptureWindow/PreparingScreenshotMode.swift Snap-O/CaptureWindow/LivePreviewManager.swift \
  Snap-O/Capture/CaptureServices.swift Snap-O/CaptureWindow/CaptureWindowController.swift \
  Snap-O/CaptureWindow/CaptureWindowMode.swift Snap-O/CaptureWindow/RecordingMode.swift \
  Snap-O/CaptureWindow/LivePreviewMode.swift Snap-O/CaptureWindow/MediaDisplayMode.swift \
  Snap-O/CaptureWindow/LivePreviewConnection.swift \
  Snap-O/LivePreview/LivePreviewThumbnail.swift \
  Snap-O/CaptureWindow/CaptureSnapshotController.swift \
  Tests/CaptureSupport/TestSupport.swift Tests/CaptureMode/CaptureModeTests.swift \
  Tests/StartupCapture/StartupCaptureTests.swift \
  -o "$TEST_DIR/startup-tests"
"$TEST_DIR/startup-tests"
xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Models/Media.swift Snap-O/LivePreview/LivePreviewSession.swift \
  Snap-O/LivePreview/LivePreviewFrameSource.swift Snap-O/Device/ADB/ADBPreviewFrameSource.swift \
  Snap-O/Device/Emulators/EmulatorServiceProtocol.swift \
  Snap-O/Device/Emulators/EmulatorPreviewFrameBuilder.swift \
  Snap-O/Capture/ShowTouchesOverride.swift Snap-O/Capture/LivePreviewService.swift \
  Snap-O/Capture/CaptureCoordinator.swift \
  Tests/StartupCapture/LivePreviewSessionTests.swift -o "$TEST_DIR/session-tests"
"$TEST_DIR/session-tests"
