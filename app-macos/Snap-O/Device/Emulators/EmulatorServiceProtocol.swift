import Foundation

@objc(EmulatorServiceProtocol)
protocol EmulatorServiceProtocol {
  func startADBServer(reply: @escaping @Sendable (Data?, String?) -> Void)
  func snapshot(_ serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void)
  func start(_ avdID: String, coldBoot: Bool, serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void)
  func delete(_ avdID: String, serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void)
  func stop(_ avdID: String, serial: String, reply: @escaping @Sendable (Data?, String?) -> Void)
}

struct EmulatorInventory: Codable {
  let devices: [ManagedEmulator]
}

struct ManagedEmulator: Codable, Identifiable, Equatable {
  enum State: String, Codable {
    case stopped, starting, running, offline, stopping, unavailable

    var title: String {
      switch self {
      case .stopped: "Stopped"
      case .starting: "Starting"
      case .running: "Running"
      case .offline: "Offline"
      case .stopping: "Stopping"
      case .unavailable: "Unavailable"
      }
    }
  }

  let id: String
  let avdName: String
  let title: String
  let platform: String
  let architecture: String
  var state: State
  var serial: String?
  var detail: String?

  var canStart: Bool {
    state == .stopped
  }

  var canStop: Bool {
    serial != nil && state != .stopping
  }

  var canDelete: Bool {
    state == .stopped && serial == nil
  }

  var canColdBoot: Bool {
    canStart || canStop
  }

  static func properties(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      let line = line.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      result[key] = value
    }
    return result
  }
}
