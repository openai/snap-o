import Foundation

actor ADBService {
  private(set) var waitingForCancellation = false

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
      waitingForCancellation = true
      try await Task.sleep(for: .seconds(60))
      throw CancellationError()
    default:
      throw ADBError.protocolFailure("Screenshot failed")
    }
  }
}
