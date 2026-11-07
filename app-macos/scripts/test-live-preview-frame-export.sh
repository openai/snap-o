#!/bin/sh
set -eu

case "${1:-}" in
  ""|--build-only|--keyboard-only|--ownership-only|--frames-only) ;;
  *) echo "Unknown test option: $1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Expected at most one test option" >&2
  exit 2
fi

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-frame-export-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift.sh"

swiftc_for_tests -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Device/ADB/ADBConnection.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Models/Media.swift Snap-O/Capture/CaptureMedia.swift \
  Snap-O/Storage/FileStore.swift Snap-O/Storage/SaveLocation.swift \
  Snap-O/LivePreview/Rendering/LivePreviewFrameExporter.swift Snap-O/LivePreview/Rendering/LivePreviewRenderer.swift \
  Snap-O/LivePreview/Rendering/LivePreviewThumbnail.swift \
  Snap-O/LivePreview/Rendering/LivePreviewFrameBuffer.swift \
  Snap-O/Device/Emulators/EmulatorPreviewFrameBuilder.swift \
  Snap-O/Capture/Review/CaptureCopyConfirmation.swift \
  Snap-O/LivePreview/Rendering/LivePreviewView.swift Snap-O/LivePreview/Input/LivePreviewMultitouch.swift Snap-O/Utilities/Perf.swift \
  Snap-O/LivePreview/Input/LivePreviewKeyboardInput.swift Snap-O/LivePreview/Input/LivePreviewKeyboardEvent.swift \
  StandaloneTests/LivePreviewFrameExport/LivePreviewFrameExportTests.swift \
  -o "$TEST_DIR/frame-export-tests"
# Compile without launching the test window when only build validation is authorized.
if [ "${1:-}" = "--build-only" ]; then exit 0; fi
# Keyboard checks use test windows; frame-copy checks use a fake renderer.
run_test "$TEST_DIR/frame-export-tests" "$@"
