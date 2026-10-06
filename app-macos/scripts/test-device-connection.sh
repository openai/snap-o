#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/snap-o-connection-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift.sh"

swiftc_for_tests -swift-version 6 -parse-as-library \
  Snap-O/Device/Device.swift Snap-O/Device/ADB/ADBSocketConnection.swift \
  StandaloneTests/DeviceConnection/DeviceConnectionTests.swift \
  -o "$TEST_DIR/connection-tests"
run_test "$TEST_DIR/connection-tests"

. "$APP_DIR/scripts/test-swift-packages.sh"
set --
for modulemap in "$BUILD_DIR/Build/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap \
  "$BUILD_DIR/SourcePackages/checkouts/"*/Sources/*/include/module.modulemap; do
  set -- "$@" -Xcc "-fmodule-map-file=$modulemap"
done
for object in "$PRODUCTS/"*.o; do
  case "$(basename "$object")" in
    Dependencies.o|Clocks.o|CombineSchedulers.o|ConcurrencyExtras.o|IssueReporting.o|*TestSupport.o) continue ;;
  esac
  set -- "$@" "$object"
done
swiftc_with_test_dependencies -swift-version 6 -parse-as-library "$@" \
  Snap-O/Device/Device.swift Snap-O/Device/ADB/ADBSocketConnection.swift \
  Snap-O/Tools/ToolHTTPTransport.swift StandaloneTests/DeviceConnection/ToolConnectionTests.swift \
  -o "$TEST_DIR/tool-connection-tests"
run_test "$TEST_DIR/tool-connection-tests"

# Exercise the real discovery client against isolated, scripted sockets.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library "$@" \
  Snap-O/Device/Device.swift Snap-O/Device/ADB/ADBSocketConnection.swift \
  Snap-O/Device/ADB/ADBClient.swift Snap-O/Device/ADB/ADBServerSession.swift \
  Snap-O/Device/ADB/RecordingSession.swift \
  Snap-O/Device/AndroidHostServiceProtocol.swift Snap-O/Device/Emulators/EmulatorConnection.swift \
  Snap-O/Device/DeviceDiscovery.swift Snap-O/Device/ScreenshotDeadline.swift \
  Snap-O/Device/ToolDiscovery.swift Snap-O/Device/ToolServerReference.swift \
  Snap-O/Device/ToolManifest.swift Snap-O/Device/ToolFrontendBundle.swift \
  Snap-O/Device/LegacyPluginMetadata.swift Snap-O/Utilities/Logging.swift \
  Snap-O/Device/AndroidHostClient.swift Snap-O/Device/Emulators/EmulatorDisplayProbe.swift \
  Snap-O/LivePreview/Input/EmulatorControlsController.swift \
  StandaloneTests/DeviceConnection/AndroidHostControlTests.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift \
  StandaloneTests/DeviceConnection/EmulatorDisplayProbeTests.swift \
  StandaloneTests/DeviceConnection/ADBServerSessionTests.swift \
  StandaloneTests/DeviceConnection/EmulatorDiscoveryTests.swift \
  -o "$TEST_DIR/emulator-discovery-tests"
run_test "$TEST_DIR/emulator-discovery-tests"

# Native operations keep one real HTTP/2 socket, even while the listener remains available.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library "$@" \
  Snap-O/Device/Emulators/EmulatorGRPCConnection.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift \
  StandaloneTests/DeviceConnection/EmulatorGRPCConnectionTests.swift \
  -o "$TEST_DIR/emulator-grpc-connection-tests"
run_test "$TEST_DIR/emulator-grpc-connection-tests"
