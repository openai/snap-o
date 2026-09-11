import Foundation

/// An Android device discovered through the host ADB server.
public struct Device: Identifiable, Hashable, Sendable {
  public let id: String
  public let model: String
  public let androidVersion: String
  public let vendorModel: String?
  public let manufacturer: String?
  public let avdName: String?

  public init(
    id: String,
    model: String,
    androidVersion: String,
    vendorModel: String?,
    manufacturer: String?,
    avdName: String?
  ) {
    self.id = id
    self.model = model
    self.androidVersion = androidVersion
    self.vendorModel = vendorModel
    self.manufacturer = manufacturer
    self.avdName = avdName
  }
}

public enum ADBError: Error, LocalizedError, Sendable {
  case adbNotFound
  case nonZeroExit(Int32, stderr: String?)
  case parseFailure(String)
  case noSuchRecording
  case alreadyRecording
  case notRecording
  case serverUnavailable(String?)
  case protocolFailure(String)
  case requestTimedOut(String)

  public var errorDescription: String? {
    switch self {
    case .adbNotFound: "adb binary not found"
    case .nonZeroExit(let code, let stderr): "adb exited with code \(code). stderr: \(stderr ?? "<none>")"
    case .parseFailure(let message): "Failed to parse adb output: \(message)"
    case .noSuchRecording: "No such recording handle"
    case .alreadyRecording: "Already recording on this device"
    case .notRecording: "Not currently recording"
    case .serverUnavailable(let message):
      "Could not connect to the adb server: \(message ?? "<unknown>")"
    case .protocolFailure(let message):
      "ADB protocol error: \(message)"
    case .requestTimedOut(let message):
      message
    }
  }
}
