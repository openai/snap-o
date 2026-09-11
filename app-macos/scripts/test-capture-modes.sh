#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-capture-mode-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Models/Media.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/Capture/PreparedLivePreview.swift Snap-O/Utilities/Perf.swift \
  Snap-O/CaptureWindow/LivePreviewManager.swift Snap-O/CaptureWindow/LivePreviewMode.swift \
  Snap-O/CaptureWindow/LivePreviewConnection.swift \
  Tests/CaptureSupport/TestSupport.swift Tests/CaptureMode/CaptureModeTests.swift \
  -o "$TEST_DIR/capture-mode-tests"
"$TEST_DIR/capture-mode-tests"
