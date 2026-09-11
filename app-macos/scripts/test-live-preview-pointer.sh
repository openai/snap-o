#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-pointer-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"

# Exercise the production sender and rotation lifecycle without injecting device input.
xcrun swiftc -swift-version 6 -parse-as-library \
  Tests/LivePreviewPointer/DeviceClientDouble.swift Snap-O/Utilities/Logging.swift \
  Snap-O/LivePreview/LivePreviewPointerBackend.swift \
  Snap-O/LivePreview/LivePreviewPointerInjector.swift \
  Snap-O/LivePreview/UInputLivePreviewPointerBackend.swift \
  Tests/LivePreviewPointer/LivePreviewPointerTests.swift -o "$TEST_DIR/pointer-tests"
"$TEST_DIR/pointer-tests"
