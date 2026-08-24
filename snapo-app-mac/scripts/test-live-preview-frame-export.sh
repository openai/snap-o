#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-frame-export-tests.XXXXXX")
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Storage/FileStore.swift Snap-O/LivePreview/LivePreviewFrameExporter.swift \
  Snap-O/LivePreview/LivePreviewView.swift Snap-O/Utilities/Perf.swift \
  Tests/LivePreviewFrameExport/LivePreviewFrameExportTests.swift \
  -o "$TEST_DIR/frame-export-tests"
# Pass --render to also check hidden decoding in a small test window.
"$TEST_DIR/frame-export-tests" "$@"
