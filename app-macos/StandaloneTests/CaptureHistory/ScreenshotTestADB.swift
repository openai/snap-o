import Foundation

actor ADBService {
  private(set) var waitingForCancellation = false {
    didSet { testChanges.signal() }
  }

  private let timesOut: Bool

  init(timesOut: Bool = false) {
    self.timesOut = timesOut
  }

  func bound(to _: DeviceTarget) -> ADBService {
    self
  }

  func exec() -> ADBService {
    self
  }

  func displayDensity(deviceID: String) throws -> Int {
    160
  }

  func screencapPNG(deviceID: String) async throws -> Data {
    switch deviceID {
    case "device-a":
      return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1kAAAAASUVORK5CYII=")!
    case "device-b":
      if timesOut { throw ADBError.requestTimedOut("Screenshot capture timed out after 2 seconds") }
      waitingForCancellation = true
      try await suspendUntilCancelled()
      throw CancellationError()
    default:
      throw ADBError.protocolFailure("Screenshot failed")
    }
  }
}

/// Deadline behavior has its own fake-clock tests; history only needs the operation's result.
enum ScreenshotDeadline {
  static func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    try await operation()
  }
}

enum EmulatorGRPCEndpoint {
  static func isEmulator(_ serial: String) -> Bool {
    serial.hasPrefix("emulator-")
  }
}
