#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-preview-lifetime.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"
TEST_PLUGINS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/host/plugins/testing"
TEST_LIBRARIES="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib"
TEST_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"

# Check command routing and connection-specific thumbnails without opening windows.
# Input and attachment cleanup checks run in test-preview-input.sh.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library -D SNAPO_STANDALONE_TESTS \
  -plugin-path "$TEST_PLUGINS" \
  -F "$TEST_FRAMEWORKS" -framework Testing -framework IssueReportingTestSupport \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS/../PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" "$PRODUCTS/DependenciesTestSupport.o" \
  Snap-O/Device/Device.swift Snap-O/Device/AndroidHostServiceProtocol.swift Snap-O/Models/Media.swift Snap-O/Utilities/Logging.swift \
  Snap-O/Models/SnapOCommand.swift Snap-O/Models/DeviceOpenRequest.swift \
  Snap-O/App/SnapOCommandCoordinator.swift Snap-OIntegrationTests/App/SnapOCommandCoordinatorTests.swift \
  Snap-O/LivePreview/Rendering/LivePreviewThumbnail.swift \
  StandaloneTests/PreviewLifetime/PreviewLifetimeTests.swift \
  -o "$TEST_DIR/preview-lifetime-tests"
run_test "$TEST_DIR/preview-lifetime-tests"
