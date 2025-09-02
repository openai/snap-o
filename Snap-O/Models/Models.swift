import Foundation

// Device discovered via `adb devices -l`
public struct Device: Identifiable, Hashable, Sendable {
  public let id: String // adb serial
  public let model: String
  public let androidVersion: String
  // Preferred display model from vendor props if available
  public let vendorModel: String?
  // Manufacturer, preferred from vendor props if available (falls back to ro.product.manufacturer)
  public let manufacturer: String?
  // Emulator AVD name (from ro.boot.qemu.avd_name), underscores replaced with spaces
  public let avdName: String?
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
