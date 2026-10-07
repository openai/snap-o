#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-runtime-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"

# Run the real app shutdown order and touch leases against gated service doubles.
swiftc_with_test_dependencies -swift-version 6 -parse-as-library \
  Snap-O/App/AppRuntime.swift Snap-O/App/AppTermination.swift \
  Snap-O/Capture/Operations/RecordingOptions.swift Snap-O/Device/Device.swift Snap-O/Device/ADBServerState.swift Snap-O/Device/DeviceTracking.swift Snap-O/Device/ADB/ADBConnection.swift Snap-O/Capture/CaptureServices.swift Snap-O/Device/ShowTouchesOverride.swift \
  Snap-O/Utilities/Logging.swift Snap-O/Utilities/Perf.swift \
  Snap-OIntegrationTests/AsyncTestSupport.swift StandaloneTests/Support/TestGate.swift \
  StandaloneTests/AppRuntime/RuntimeTestServices.swift StandaloneTests/AppRuntime/AppRuntimeTests.swift StandaloneTests/AppRuntime/AppTerminationTests.swift \
  -o "$TEST_DIR/runtime-tests"
run_test "$TEST_DIR/runtime-tests"
