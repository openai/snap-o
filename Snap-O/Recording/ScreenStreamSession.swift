import Foundation

final class ScreenStreamSession: @unchecked Sendable {
  let deviceID: String
  let startedAt: Date
  private let connection: ADBSocketConnection

  init(deviceID: String, connection: ADBSocketConnection, startedAt: Date) {
    self.deviceID = deviceID
    self.connection = connection
    self.startedAt = startedAt
  }

  func read(maxLength: Int) throws -> Data? {
    try connection.readChunk(maxLength: maxLength)
  }

  func close() {
    connection.close()
  }
}
