#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-recording-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"

# Exercise the recording owners with deterministic ADB sessions and placeholder files.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library \
  Snap-O/Capture/Operations/RecordingOptions.swift Snap-O/Device/Device.swift Snap-O/Models/Device+Formatting.swift Snap-O/Models/Media.swift Snap-O/Capture/Export/VideoFileClient.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/Capture/Operations/CaptureTimestampSource.swift Snap-O/App/StartupCapturePreparation.swift \
  Snap-O/Capture/Operations/CaptureCoordinator.swift Snap-O/Device/ShowTouchesOverride.swift \
  Snap-O/Capture/Operations/ScreenRecording.swift Snap-O/Capture/Operations/ADBScreenRecording.swift Snap-O/Capture/Operations/ADBRecordingFile.swift \
  Snap-O/Capture/Operations/CaptureBatch.swift Snap-O/Capture/Operations/ScreenshotCapture.swift Snap-O/Capture/Operations/RecordingCapture.swift \
  Snap-O/Capture/Operations/ScreenshotService.swift Snap-O/Device/ScreenshotDeadline.swift Snap-O/Utilities/Perf.swift \
  Snap-O/History/CaptureHistoryEntry.swift Snap-O/History/CaptureHistoryRepository.swift \
  Snap-O/Storage/FileStore.swift Snap-O/Utilities/Logging.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift \
  StandaloneTests/Support/RecordingSessionDouble.swift StandaloneTests/Recording/RecordingTestADB.swift StandaloneTests/Recording/RecordingTests.swift StandaloneTests/Recording/CaptureBatchTests.swift StandaloneTests/Recording/RecordingTeardownTests.swift \
  -o "$TEST_DIR/recording-tests"
run_test "$TEST_DIR/recording-tests"
