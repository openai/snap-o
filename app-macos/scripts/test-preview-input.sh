#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-preview-input.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"
TEST_PLUGINS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/host/plugins/testing"
TEST_LIBRARIES="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib"
TEST_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"

# The default run opens no windows. SNAPO_TEST_WINDOWS=1 enables native visibility checks.
# Device-facing factories fail immediately; test backends control every operation.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library -D SNAPO_STANDALONE_TESTS \
  -plugin-path "$TEST_PLUGINS" \
  -F "$TEST_FRAMEWORKS" -framework Testing -framework IssueReportingTestSupport \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS/../PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" "$PRODUCTS/DependenciesTestSupport.o" \
  Snap-O/Device/Device.swift Snap-O/Device/AndroidHostServiceProtocol.swift Snap-O/Models/Media.swift Snap-O/Device/ADB/ADBSocketConnection.swift \
  Snap-O/Device/ADB/ADBVirtualTouchscreen.swift Snap-O/Device/ADB/DeviceKeyboardTransport.swift \
  Snap-O/Device/Clipboard/ClipboardTransport.swift Snap-O/Device/Clipboard/ClipboardSyncState.swift \
  Snap-O/Device/Clipboard/DeviceClipboardTransport.swift Snap-O/Device/Clipboard/DeviceClipboardProtocol.swift Snap-O/App/AppSettings.swift \
  Snap-O/Device/LivePreviewRotation.swift Snap-O/Utilities/Logging.swift \
  Snap-O/LivePreview/Input/LivePreviewPointerBackend.swift Snap-O/LivePreview/Input/LivePreviewPointerInjector.swift \
  Snap-O/LivePreview/Input/ShellLivePreviewPointerBackend.swift Snap-O/LivePreview/Input/UInputLivePreviewPointerBackend.swift \
  Snap-O/Device/ADB/LivePreviewKeyboard+Device.swift \
  Snap-O/LivePreview/Input/LivePreviewKeyboard.swift Snap-O/LivePreview/Input/LivePreviewKeyboardEvent.swift \
  Snap-O/LivePreview/Rendering/LivePreviewFrameSource.swift Snap-O/LivePreview/Rendering/LivePreviewSession.swift \
  Snap-O/LivePreview/PreviewVideo.swift Snap-O/LivePreview/Rendering/LivePreviewRenderer.swift \
  Snap-O/LivePreview/Input/TextPasteboard.swift Snap-O/LivePreview/Input/ClipboardSync.swift Snap-O/Device/ShowTouchesOverride.swift \
  Snap-O/Capture/Operations/CaptureCoordinator.swift \
  Snap-O/LivePreview/PreviewHint.swift \
  Snap-O/App/StartupCapturePreparation.swift Snap-O/Utilities/Perf.swift \
  Snap-O/LivePreview/LivePreviewDevice.swift Snap-O/LivePreview/Rendering/LivePreviewThumbnail.swift \
  Snap-O/LivePreview/Views/LivePreviewThumbnailView.swift \
  Snap-O/UI/WindowVisibilityReader.swift StandaloneTests/PreviewInput/WindowVisibilityTests.swift \
  Snap-O/LivePreview/Input/DeviceFileDrop.swift Snap-O/Device/ADB/DeviceFileCommand.swift Snap-O/LivePreview/Input/EmulatorControlsController.swift \
  Snap-O/LivePreview/DevicePreview.swift Snap-O/LivePreview/LivePreviewService.swift \
  Snap-OIntegrationTests/LivePreview/SharedPreviewTestSupport.swift Snap-OIntegrationTests/AsyncTestSupport.swift Snap-OIntegrationTests/TextPasteboardDouble.swift StandaloneTests/Support/TestGate.swift \
  StandaloneTests/FileDrop/FileTransferProbe.swift StandaloneTests/FileDrop/FileDropTests.swift \
  StandaloneTests/PreviewInput/DeviceClientDouble.swift StandaloneTests/PreviewInput/PreviewSetupTests.swift StandaloneTests/PreviewInput/PreviewRequestTests.swift StandaloneTests/PreviewInput/TouchSettingTests.swift StandaloneTests/PreviewInput/PreviewInputTests.swift \
  -o "$TEST_DIR/preview-input-tests"
run_test "$TEST_DIR/preview-input-tests" "$@"
