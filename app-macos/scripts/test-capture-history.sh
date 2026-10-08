#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-history-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift.sh"

swiftc_for_tests -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Device/ADB/ADBConnection.swift Snap-O/Models/Media.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/History/CaptureHistoryEntry.swift \
  Snap-O/History/CaptureHistoryRepository.swift Snap-O/History/CaptureHistoryItemDrag.swift \
  Snap-O/History/CaptureHistoryDropTarget.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift \
  Snap-O/Capture/Operations/CaptureCoordinator.swift Snap-O/Utilities/Perf.swift \
  Snap-O/Capture/Operations/CaptureOperation.swift Snap-O/Capture/Operations/ScreenshotCapture.swift \
  Snap-O/Capture/Operations/ScreenshotService.swift Snap-O/Capture/Operations/CaptureTimestampSource.swift \
  Snap-O/Storage/FileStore.swift Snap-O/Utilities/Logging.swift \
  StandaloneTests/CaptureHistory/ScreenshotTestADB.swift \
  StandaloneTests/CaptureHistory/CaptureHistoryTests.swift \
  -o "$TEST_DIR/history-tests"
run_test "$TEST_DIR/history-tests"
