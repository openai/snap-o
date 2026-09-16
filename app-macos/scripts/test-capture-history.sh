#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-history-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Models/Media.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/History/CaptureHistoryEntry.swift \
  Snap-O/History/CaptureHistoryRepository.swift Snap-O/History/CaptureHistoryItemDrag.swift \
  Snap-O/History/CaptureHistoryDropTarget.swift \
  Snap-O/Capture/ScreenshotService.swift Snap-O/Capture/CaptureTimestampSource.swift \
  Snap-O/Storage/FileStore.swift Snap-O/Utilities/Logging.swift \
  Tests/CaptureHistory/ScreenshotTestADB.swift \
  Tests/CaptureHistory/CaptureHistoryTests.swift \
  -o "$TEST_DIR/history-tests"
"$TEST_DIR/history-tests"
