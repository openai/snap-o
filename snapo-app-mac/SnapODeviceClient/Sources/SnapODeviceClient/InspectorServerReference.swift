import Foundation

public struct InspectorServerReference: Codable, Hashable, Sendable {
  public let deviceId: String
  public let socketName: String

  public init(deviceId: String, socketName: String) {
    self.deviceId = deviceId
    self.socketName = socketName
  }

  public var key: String {
    "\(deviceId)\0\(socketName)"
  }

  public var identifier: String {
    "\(deviceId)/\(socketName)"
  }
}
