import Foundation

public final class ScreenStreamSession: @unchecked Sendable {
  public let deviceID: String
  public let startedAt: Date
  private let connection: ADBSocketConnection

  init(deviceID: String, connection: ADBSocketConnection, startedAt: Date) {
    self.deviceID = deviceID
    self.connection = connection
    self.startedAt = startedAt
  }

  public func read(maxLength: Int) throws -> Data? {
    try connection.readChunk(maxLength: maxLength)
  }

  public func close() {
    connection.close()
  }
}
