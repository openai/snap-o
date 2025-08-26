import Foundation

public struct RecordingHandle: Sendable, Equatable {
  let token: UUID
  public let deviceID: String
}
