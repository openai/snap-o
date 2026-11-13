import Dependencies
import Foundation

extension ADBClient {
  func waitUntilBooted(_ target: DeviceTarget) async throws {
    @Dependency(\.continuousClock)
    var clock
    var delay = Duration.seconds(1)
    while true {
      try Task.checkCancellation()
      _ = try target.requireTransport(for: target.serial)
      if await (try? isBootComplete(deviceID: target.serial)) == true { return }
      try await clock.sleep(for: delay)
      delay = min(delay * 2, .seconds(10))
    }
  }
}

/// Owns a physical stream between ADB discovery and the preview window claiming it.
final class DiscoveredVideo: Sendable {
  let target: DeviceTarget
  let stream: Task<DeviceHelper.Session, Error>
  let wake: Task<Void, Error>
  private let boot: Task<Void, Error>

  convenience init?(target: DeviceTarget) {
    self.init(target: target, client: ADBClient())
  }

  init?(target: DeviceTarget, client: ADBClient) {
    guard !target.isLocalEmulator, target.isValid else { return nil }
    self.target = target
    let exec = client.bound(to: target)
    let boot = Task.detached(priority: .userInitiated) {
      try await exec.waitUntilBooted(target)
    }
    self.boot = boot
    let wake = Task.detached(priority: .userInitiated) {
      try await boot.value
      try Task.checkCancellation()
      _ = try? await exec.withTimeout(.seconds(1)).keyEvent(deviceID: target.serial, keyCode: "KEYCODE_WAKEUP")
    }
    self.wake = wake
    stream = Task.detached(priority: .userInitiated) {
      try await boot.value
      try Task.checkCancellation()
      let helper = try DeviceHelper(DeviceHelper.bundledBytes())
      let session = try await helper.connect(.video, serial: target.serial, adb: exec)
      do {
        try await wake.value
        try Task.checkCancellation()
        try DeviceVideoPacket.validateHeader(session.header)
        try session.connection.writeFully(ADBShellV2Stream.standardInput(Data([5])))
        #if PERF_TRACING
        Perf.startupEvent("device video capture requested", deviceID: target.serial)
        #endif
        return session
      } catch {
        session.connection.close()
        throw error
      }
    }
  }

  func cancel() {
    boot.cancel()
    wake.cancel()
    stream.cancel()
  }

  func close() async {
    cancel()
    if case .success(let session) = await stream.result { session.connection.close() }
    _ = await wake.result
    _ = await boot.result
  }
}
