#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-emulator-preview-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

xcrun swiftc -swift-version 6 -parse-as-library \
  Snap-O/Device/Emulators/EmulatorServiceProtocol.swift \
  Snap-O/Device/Emulators/EmulatorPreviewFrameBuilder.swift \
  EmulatorService/EmulatorCommand.swift EmulatorService/EmulatorPreviewDiscovery.swift \
  Tests/EmulatorPreview/EmulatorPreviewTests.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
