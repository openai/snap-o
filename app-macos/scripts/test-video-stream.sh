#!/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap-o-video-stream.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$APP_DIR"
. "$APP_DIR/scripts/test-swift-packages.sh"
TEST_PLUGINS="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/host/plugins/testing"
TEST_LIBRARIES="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib"
TEST_FRAMEWORKS="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"

# Exercise the real shared stream owner against simulated blocking device I/O.
# The emulator source imports the app's statically linked gRPC/NIO products.
set --
for module_map in "$BUILD_DIR/Build/Intermediates.noindex/GeneratedModuleMaps/"C*.modulemap \
  "$BUILD_DIR/SourcePackages/checkouts/swift-nio/Sources/CNIOWindows/include/module.modulemap" \
  "$BUILD_DIR/SourcePackages/checkouts/swift-atomics/Sources/_AtomicsShims/include/module.modulemap"; do
  set -- "$@" -Xcc "-fmodule-map-file=$module_map"
done
for module in Atomics CGRPCNIOTransportZlib CNIOAtomics CNIODarwin CNIOFreeBSD CNIOLLHTTP \
  CNIOLinux CNIOOpenBSD CNIOPosix CNIOWASI CNIOWindows ContainersPreview DequeModule \
  GRPCCore GRPCNIOTransportCore GRPCNIOTransportHTTP2TransportServices InternalCollectionsUtilities \
  NIO NIOConcurrencyHelpers NIOCore NIOEmbedded NIOExtras NIOFoundationCompat \
  NIOFoundationEssentialsCompat NIOHPACK NIOHTTP1 NIOHTTP2 NIOPosix NIOTLS NIOTransportServices \
  SwiftProtobuf _AtomicsShims _NIOBase64 _NIODataStructures; do
  set -- "$@" "$PRODUCTS/$module.o"
done
swiftc_with_test_dependencies -swift-version 6 -parse-as-library -D SNAPO_STANDALONE_TESTS \
  "$@" -lz -plugin-path "$TEST_PLUGINS" \
  -F "$TEST_FRAMEWORKS" -framework Testing -framework IssueReportingTestSupport \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS/../PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" "$PRODUCTS/DependenciesTestSupport.o" \
  Snap-O/Device/Device.swift Snap-O/Models/Media.swift \
  Snap-O/Device/AndroidHostServiceProtocol.swift \
  Snap-O/Device/Emulators/EmulatorGRPCConnection.swift \
  Snap-O/Device/Emulators/EmulatorGRPCConnection+Device.swift \
  Snap-O/Device/Emulators/EmulatorPreviewFrameSource.swift \
  Snap-O/LivePreview/Rendering/LivePreviewFrameBuffer.swift \
  Snap-O/Device/Emulators/EmulatorPreviewFrameBuilder.swift \
  Snap-O/Device/Emulators/emulator_preview.pb.swift \
  Snap-O/Capture/Operations/NativeScreenRecording.swift Snap-O/Capture/Operations/ScreenRecording.swift \
  Snap-O/Device/Video/DeviceVideoConnection.swift \
  Snap-O/Device/Video/DeviceVideoSource.swift Snap-O/Device/Video/DeviceVideoPacket.swift \
  Snap-O/LivePreview/Rendering/LivePreviewFrameSource.swift Snap-O/LivePreview/Rendering/LivePreviewSession.swift Snap-O/LivePreview/PreviewVideo.swift \
  StandaloneTests/Support/TestGate.swift Snap-OIntegrationTests/AsyncTestSupport.swift \
  StandaloneTests/VideoStream/VideoConnectionDouble.swift StandaloneTests/VideoStream/EmulatorEndpointDouble.swift \
  Snap-OIntegrationTests/LivePreview/SharedPreviewVideoTests.swift Snap-OUnitTests/LivePreview/PreviewVideoTests.swift \
  Snap-OUnitTests/LivePreview/LivePreviewSessionStateTests.swift \
  StandaloneTests/VideoStream/VideoStreamTests.swift \
  -o "$TEST_DIR/video-stream-tests"
# Bundle lookup uses this synthetic resource; the fake connection never executes it.
printf 'test helper' > "$TEST_DIR/snapo-device-helper.jar"
run_test "$TEST_DIR/video-stream-tests"
