import Foundation

/// Console tests inject their input backends. Any accidental device access fails.
public struct ADBClient: Sendable {
  let setup: PreviewSetupProbe?
  let requests: PreviewRequestProbe?
  private var timeout: Duration?
  private var target: DeviceTarget?
  private let files: FileTransferProbe?
  init(setup: PreviewSetupProbe? = nil, requests: PreviewRequestProbe? = nil) {
    self.setup = setup
    self.requests = requests
    files = nil
  }

  init(probe: FileTransferProbe) {
    setup = nil
    requests = nil
    files = probe
  }

  func bound(to target: DeviceTarget) -> Self {
    var client = self
    client.target = target
    return client
  }

  func withTimeout(_ timeout: Duration) -> Self {
    var client = self
    client.timeout = timeout
    return client
  }

  func makeConnection() async throws -> ADBSocketConnection {
    throw ADBError.protocolFailure("Unexpected device connection in input tests")
  }

  func isBootComplete(deviceID: String) async throws -> Bool {
    guard let setup else { throw unexpected() }
    return try await setup.readBoot()
  }

  func displayDensity(deviceID: String) async throws -> Double {
    guard let setup else { throw unexpected() }
    return try await setup.readDensity()
  }

  func getShowTouches(deviceID: String) async throws -> Bool {
    guard let setup else { throw unexpected() }
    return try await setup.readTouches(timeout: timeout)
  }

  func setShowTouches(deviceID: String, enabled: Bool) async throws {
    guard let setup else { throw unexpected() }
    try await setup.writeTouches(enabled, timeout: timeout)
  }

  func keyEvent(deviceID: String, keyCode: String) async throws -> String {
    if let requests {
      try await requests.run(target: target)
      return ""
    }
    guard let setup else { throw unexpected() }
    try await setup.wake(keyCode)
    return ""
  }

  func screencapPNG(deviceID: String) async throws -> Data {
    guard let requests else { throw unexpected() }
    try await requests.run(target: target)
    return Data("screenshot".utf8)
  }

  private func unexpected() -> ADBError {
    ADBError.protocolFailure("Unexpected device access in input tests")
  }

  private func fileTransfer(for serial: String) throws -> (DeviceTarget, FileTransferProbe) {
    guard let target, let files else { throw unexpected() }
    _ = try target.requireTransport(for: serial)
    return (target, files)
  }

  func downloadsDirectory(deviceID: String) async throws -> String {
    _ = try fileTransfer(for: deviceID)
    return "/storage/emulated/0/Download"
  }

  func fileExists(deviceID: String, path: String) async throws -> Bool {
    let (_, files) = try fileTransfer(for: deviceID)
    return await files.exists
  }

  func copyFile(
    deviceID: String, localURL: URL, destination: String, replace: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String? {
    let (target, files) = try fileTransfer(for: deviceID)
    try await files.transfer(target: target, progress: progress)
    return nil
  }

  func installAPK(deviceID: String, localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
    let (target, files) = try fileTransfer(for: deviceID)
    try await files.transfer(target: target, progress: progress)
  }

  public func runShellString(deviceID: String, command: String) async throws -> String {
    throw ADBError.protocolFailure("Unexpected shell command in input tests")
  }
}

actor ADBService {
  private let setup: PreviewSetupProbe?
  private let requests: PreviewRequestProbe?
  init(setup: PreviewSetupProbe? = nil, requests: PreviewRequestProbe? = nil) {
    self.setup = setup
    self.requests = requests
  }

  func exec() -> ADBClient {
    ADBClient(setup: setup, requests: requests)
  }
}

enum EmulatorRotationClient {
  static func rotation(target: DeviceTarget) async throws -> ADBDisplayRotation {
    throw ADBError.protocolFailure("Unexpected emulator query in input tests")
  }

  static func rotate(target: DeviceTarget, left: Bool) async throws {
    throw ADBError.protocolFailure("Unexpected emulator rotation in input tests")
  }
}

@MainActor
final class DeviceVideoSource: LivePreviewFrameSource {
  static var sources: [DeviceTarget: PreviewSetupSource] = [:]
  let hasIndependentFrames = true
  private let source: PreviewSetupSource
  init(target: DeviceTarget) {
    guard let source = Self.sources[target] else {
      preconditionFailure("Shared preview tests must inject a frame source")
    }
    self.source = source
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    source.start(deliver: deliver)
  }

  func stop() {
    source.stop()
  }

  func waitUntilStopped() async {
    await source.waitUntilStopped()
  }
}

extension ClipboardSync {
  convenience init(settings: AppSettings, maySynchronize: @escaping @MainActor () -> Bool) {
    self.init(settings: settings, maySynchronize: maySynchronize) { _, _ in
      preconditionFailure("Shared preview tests must inject a clipboard transport")
    }
  }
}

@MainActor
final class ScreenshotCapture {
  var isComplete: Bool {
    false
  }

  func start() {
    preconditionFailure("Unexpected screenshot in input tests")
  }

  func close() async {}
}
