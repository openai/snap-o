#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-export-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift.sh"

swiftc_for_tests -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Models/Media.swift Snap-O/Capture/CaptureMedia.swift \
  Snap-O/Storage/StagedFileExport.swift \
  Snap-O/CaptureWindow/CaptureTrimRange.swift \
  Snap-O/CaptureWindow/CaptureCropGeometry.swift Snap-O/CaptureWindow/CaptureCropExporter.swift \
  Tests/CaptureExport/CaptureExportSandboxTests.swift \
  -o "$TEST_DIR/export-tests"
mkdir "$TEST_DIR/destination"
run_test /usr/bin/sandbox-exec \
  -D "EXPORT_DIRECTORY=$TEST_DIR/destination" \
  -f Tests/CaptureExport/selected-files.sb \
  "$TEST_DIR/export-tests" "$TEST_DIR/destination"
