#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-recording-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"

# Exercise the recording service with deterministic ADB sessions and real video files.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Models/Device+Formatting.swift Snap-O/Models/Media.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/Capture/CaptureTimestampSource.swift \
  Snap-O/Capture/CaptureCoordinator.swift Snap-O/Capture/ShowTouchesOverride.swift \
  Snap-O/Capture/ScreenRecording.swift Snap-O/Capture/RecordingService.swift \
  Snap-O/History/CaptureHistoryEntry.swift Snap-O/History/CaptureHistoryRepository.swift \
  Snap-O/Storage/FileStore.swift Snap-O/Utilities/Logging.swift \
  Tests/Recording/RecordingTestADB.swift Tests/Recording/RecordingTests.swift \
  -o "$TEST_DIR/recording-tests"
run_test "$TEST_DIR/recording-tests"
