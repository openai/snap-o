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
  Snap-OTests/Tools/ToolTestFixtures.swift \
  Snap-O/Tools/ToolHTTPService.swift \
  Snap-O/Tools/ToolService.swift \
  Snap-OTests/AsyncTestSupport.swift Tests/Support/TestGate.swift Tests/Support/DeviceManagerFake.swift \
  Tests/ToolRecovery/ToolRecoveryTests.swift -o "$TEST_DIR/tool-recovery-tests"
"$TEST_DIR/tool-recovery-tests"
