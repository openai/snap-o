#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-tool-recovery.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library \
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
  Tests/ToolSelection/ToolTestFixtures.swift \
  Snap-O/Tools/ToolSelection.swift \
  Snap-O/Tools/AppToolModel.swift \
  Snap-O/Tools/ToolHTTPService.swift \
  Snap-O/Tools/ToolService.swift \
  Tests/ToolRecovery/ToolRecoveryTests.swift -o "$TEST_DIR/tool-recovery-tests"
"$TEST_DIR/tool-recovery-tests"
