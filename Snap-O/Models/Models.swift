import Foundation

// Device discovered via `adb devices -l`
public struct Device: Identifiable, Hashable, Sendable {
  public let id: String // adb serial
  public let model: String
  public let androidVersion: String
}

public enum ADBError: Error, LocalizedError {
  case adbNotFound
  case nonZeroExit(Int32, stderr: String?)
  case parseFailure(String)
  case noSuchRecording
  case alreadyRecording
  case notRecording

  public var errorDescription: String? {
    switch self {
    case .adbNotFound: "adb binary not found"
    case .nonZeroExit(let code, let stderr): "adb exited with code \(code). stderr: \(stderr ?? "<none>")"
    case .parseFailure(let msg): "Failed to parse adb output: \(msg)"
    case .noSuchRecording: "No such recording handle"
    case .alreadyRecording: "Already recording on this device"
    case .notRecording: "Not currently recording"
    }
  }
}
