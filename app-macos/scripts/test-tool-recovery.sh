#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-tool-recovery.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

# Use the same resolved networking dependencies as the app.
BUILD_DIR=${SNAPO_DERIVED_DATA:-"$TEST_DIR/xcode"}
CONFIGURATION=${SNAPO_TEST_CONFIGURATION:-Local}
if [ -z "${SNAPO_DERIVED_DATA:-}" ]; then
  xcodebuild -quiet -project Snap-O.xcodeproj -scheme Snap-O \
    -configuration "$CONFIGURATION" -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
fi
PRODUCTS="$BUILD_DIR/Build/Products/$CONFIGURATION"
export LLVM_PROFILE_FILE="$TEST_DIR/%m.profraw"
set --
for modulemap in "$BUILD_DIR/Build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap \
  "$BUILD_DIR/SourcePackages/checkouts/"*/Sources/*/include/module.modulemap; do
  set -- "$@" -Xcc "-fmodule-map-file=$modulemap"
done

xcrun swiftc -swift-version 6 -parse-as-library -profile-generate -D SNAPO_STANDALONE_TESTS \
  -I "$PRODUCTS" "$@" "$PRODUCTS/"*.o \
  Snap-O/Device/Device.swift \
  Snap-O/Device/ToolServerReference.swift \
  Snap-O/Device/ToolDiscovery.swift \
  Snap-O/Device/ToolManifest.swift \
  Snap-O/Device/LegacyPluginMetadata.swift \
  Snap-O/Device/DeviceDiscovery.swift \
  Tests/ToolRecovery/DeviceClientDouble.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Device/DeviceTracker.swift \
  Snap-O/Tools/ToolModels.swift \
  Snap-O/Tools/ToolMetadata.swift \
  Snap-O/Tools/ToolHTTPTransport.swift \
  Snap-OTests/Tools/ToolTestFixtures.swift \
  Snap-O/Tools/ToolHTTPService.swift \
  Snap-O/Tools/ToolService.swift \
  Tests/Support/DeviceManagerFake.swift \
  Tests/ToolRecovery/ToolRecoveryTests.swift -o "$TEST_DIR/tool-recovery-tests"
"$TEST_DIR/tool-recovery-tests"
