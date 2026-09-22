#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-frame-export-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Storage/FileStore.swift Snap-O/Storage/SaveLocation.swift \
  Snap-O/LivePreview/LivePreviewFrameExporter.swift \
  Snap-O/LivePreview/LivePreviewThumbnail.swift \
  Snap-O/Device/Emulators/EmulatorPreviewFrameBuilder.swift \
  Snap-O/CaptureWindow/CaptureCopyConfirmation.swift \
  Snap-O/LivePreview/LivePreviewView.swift Snap-O/Utilities/Perf.swift \
  Tests/LivePreviewFrameExport/LivePreviewFrameExportTests.swift \
  -o "$TEST_DIR/frame-export-tests"
# Export assertions run in Snap-OTests; this checks rendering in a test window.
"$TEST_DIR/frame-export-tests" "$@"
