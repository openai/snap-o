#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-tool-recovery.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

. "$APP_DIR/scripts/test-swift-packages.sh"
set --
for modulemap in "$BUILD_DIR/Build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap \
  "$BUILD_DIR/SourcePackages/checkouts/"*/Sources/*/include/module.modulemap; do
  set -- "$@" -Xcc "-fmodule-map-file=$modulemap"
done

# These modules are provided by the shared frameworks or only support XCTest.
for object in "$PRODUCTS/"*.o; do
  case "$(basename "$object")" in
    Dependencies.o|Clocks.o|CombineSchedulers.o|ConcurrencyExtras.o|IssueReporting.o|*TestSupport.o) continue ;;
  esac
  set -- "$@" "$object"
done

swiftc_with_test_dependencies -swift-version 6 -parse-as-library -D SNAPO_STANDALONE_TESTS \
  "$@" \
  Snap-O/Device/ADBServerState.swift Snap-O/Device/Device.swift Snap-O/Device/DeviceTracking.swift Snap-O/Device/ADB/ADBConnection.swift \
  Snap-O/Device/ToolServerReference.swift \
  Snap-O/Device/ToolDiscovery.swift \
  Snap-O/Device/ToolManifest.swift \
  Snap-O/Device/LegacyPluginMetadata.swift \
  Snap-O/Device/DeviceDiscovery.swift Snap-O/Device/ADB/DeviceDiscovery+ADB.swift \
  StandaloneTests/ToolRecovery/DeviceClientDouble.swift Snap-O/Models/Device+Formatting.swift \
  Snap-O/Device/DeviceTracker.swift \
  Snap-O/Tools/ToolModels.swift \
  Snap-O/Tools/ToolMetadata.swift \
  Snap-OIntegrationTests/Tools/ToolTestFixtures.swift \
  Snap-O/Tools/ToolHTTPService.swift \
  Snap-O/Tools/ToolService.swift \
  Snap-O/Tools/ToolSelection.swift Snap-O/Tools/AppToolPresentation.swift \
  Snap-O/Tools/AppToolModel.swift Snap-O/Tools/ToolHostModel.swift Snap-O/Tools/ToolSession.swift \
  Snap-O/Tools/ToolWebPolicy.swift Snap-O/Tools/ToolPageContainer.swift StandaloneTests/ToolRecovery/ToolWebDouble.swift \
  StandaloneTests/ToolRecovery/ToolLifecycleTests.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift StandaloneTests/Support/DeviceManagerFake.swift \
  StandaloneTests/ToolRecovery/ToolRecoveryTests.swift -o "$TEST_DIR/tool-recovery-tests"
run_test "$TEST_DIR/tool-recovery-tests"
