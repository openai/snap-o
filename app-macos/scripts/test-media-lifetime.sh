#!/bin/sh
set -eu

case "${1:-}" in
  ""|--windows) ;;
  *) echo "Unknown test option: $1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Expected at most one test option" >&2
  exit 2
fi

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-media-lifetime.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"
TEST_PLUGINS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/host/plugins/testing"
TEST_LIBRARIES="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib"
TEST_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"

# Real file ownership and export code, with controlled preparation and no app or windows.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library -D SNAPO_STANDALONE_TESTS \
  -plugin-path "$TEST_PLUGINS" \
  -F "$TEST_FRAMEWORKS" -framework Testing -framework IssueReportingTestSupport \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS/../PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" "$PRODUCTS/DependenciesTestSupport.o" \
  Snap-O/Capture/Operations/RecordingOptions.swift Snap-O/Device/Device.swift Snap-O/Device/ADB/ADBConnection.swift Snap-O/Models/Device+Formatting.swift Snap-O/Models/Media.swift Snap-O/Capture/Export/VideoFileClient.swift Snap-O/Utilities/Logging.swift \
  Snap-O/Capture/CaptureMedia.swift Snap-O/Capture/Export/CaptureExportRequest.swift Snap-O/Capture/Operations/CaptureBatch.swift \
  Snap-O/Capture/Review/CaptureCropGeometry.swift Snap-O/Capture/Review/CaptureTrimRange.swift \
  Snap-O/Capture/Export/CaptureCropExporter.swift Snap-O/Capture/Review/CaptureReviewDragExport.swift \
  Snap-O/Capture/Review/CaptureReviewState.swift Snap-O/Capture/Review/CaptureReviewPlayback.swift \
  Snap-O/Capture/Review/CaptureTrimSession.swift Snap-O/LivePreview/PreviewHint.swift \
  Snap-O/Storage/FileStore.swift Snap-O/Storage/StagedFileExport.swift Snap-O/Capture/Export/CaptureMediaExport.swift \
  Snap-O/LivePreview/Rendering/LivePreviewFrameExporter.swift \
  Snap-O/History/CaptureHistoryEntry.swift Snap-O/History/CaptureHistoryRepository.swift Snap-O/History/CaptureHistory.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift \
  Snap-O/Capture/CapturePaneSession.swift \
  Snap-O/Workspace/CaptureWindowSession.swift Snap-O/Workspace/WorkspaceLayoutController.swift Snap-O/App/CaptureWorkspaces.swift \
  Snap-O/Capture/CaptureServices.swift Snap-O/LivePreview/LivePreviewDevice.swift \
  Snap-O/Device/ADBServerState.swift Snap-O/Models/SnapOCommand.swift Snap-O/Models/DeviceOpenRequest.swift \
  StandaloneTests/CapturePane/PaneDependencies.swift StandaloneTests/CapturePane/CapturePaneTests.swift StandaloneTests/CapturePane/CaptureStartupTests.swift StandaloneTests/CapturePane/WorkspaceLifetimeTests.swift \
  StandaloneTests/MediaLifetime/MediaLifetimeTests.swift \
  -o "$TEST_DIR/media-lifetime-tests"
if [ "${1:-}" = --windows ]; then
  run_test "$TEST_DIR/media-lifetime-tests" --windows --filter 'CapturePaneTests/(hiddenLaunchWindowCanBeReusedThenClosed|remountKeepsTheWindowSessionAndOtherWindowsPreview)'
else
  run_test "$TEST_DIR/media-lifetime-tests"
fi
