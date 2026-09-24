import Foundation

@objc(EmulatorServiceProtocol)
protocol EmulatorServiceProtocol {
  func previewEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void)
  func rotationEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void)
  func clipboardEndpoint(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void)
  func startADBServer(reply: @escaping @Sendable (Data?, String?) -> Void)
  func snapshot(_ serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void)
  func start(_ avdID: String, coldBoot: Bool, serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void)
  func delete(_ avdID: String, serials: [String], reply: @escaping @Sendable (Data?, String?) -> Void)
  func stop(_ avdID: String, serial: String, reply: @escaping @Sendable (Data?, String?) -> Void)
  func controls(_ serial: String, reply: @escaping @Sendable (Data?, String?) -> Void)
  func control(_ serial: String, avdPath: String, action: String, reply: @escaping @Sendable (Data?, String?) -> Void)
}

enum EmulatorControlAction: String, Codable, CaseIterable {
  case closed, halfOpen, open
  case phone, foldable, tablet, desktop

  var displayModeID: Int? {
    switch self {
    case .phone: 0
    case .foldable: 1
    case .tablet: 2
    case .desktop: 3
    default: nil
    }
  }

  var consoleCommand: String {
    switch self {
    case .closed: "posture 1"
    case .halfOpen: "posture 2"
    case .open: "posture 3"
    case .phone: "resize-display 0"
    case .foldable: "resize-display 1"
    case .tablet: "resize-display 2"
    case .desktop: "resize-display 3"
    }
  }
}

struct EmulatorControls: Codable {
  let avdPath: String
  let actions: [EmulatorControlAction]
  let displayModes: [EmulatorDisplayMode]
  let currentDisplayMode: EmulatorControlAction?
  let currentPosture: EmulatorControlAction?

  var postures: [EmulatorControlAction] {
    [.closed, .halfOpen, .open].filter(actions.contains)
  }

  init(avdPath: String, commands: String, properties: [String: String], displaySize: String? = nil, hingeAngle: Double? = nil) {
    self.avdPath = avdPath
    let commands = Set(commands.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    })
    var actions: [EmulatorControlAction] = []
    let presets = EmulatorDisplayMode.parse(properties["hw.resizable.configs"] ?? "").filter {
      $0.isSupported(by: displaySize)
    }
    displayModes = commands.contains("resize-display") ? presets : []
    let size = displaySize ?? "Physical size: \(properties["hw.lcd.width"] ?? "")x\(properties["hw.lcd.height"] ?? "")"
    currentDisplayMode = presets.first { $0.matches(size) }?.action
    actions.append(contentsOf: displayModes.map(\.action))
    let hasHinge = ["yes", "true", "1"].contains(properties["hw.sensor.hinge"] ?? "")
    var supportedPostures: [EmulatorControlAction] = []
    if commands.contains("posture"), hasHinge {
      let values = Set((properties["hw.sensor.posture_list"] ?? "").split(separator: ",").compactMap {
        Int($0.trimmingCharacters(in: .whitespaces))
      })
      for (value, action) in [(1, EmulatorControlAction.closed), (2, .halfOpen), (3, .open)] where values.contains(value) {
        supportedPostures.append(action)
      }
    }
    currentPosture = Self.posture(at: hingeAngle, properties: properties).flatMap { supportedPostures.contains($0) ? $0 : nil }
    let isResizable = properties["hw.device.name"] == "resizable" || !presets.isEmpty
    let foldableID = Int(properties["hw.sensor.hinge.resizable.config"] ?? "1")
    if !isResizable || (foldableID != nil && currentDisplayMode?.displayModeID == foldableID) {
      actions.append(contentsOf: supportedPostures)
    }
    self.actions = actions
  }

  private static func posture(at angle: Double?, properties: [String: String]) -> EmulatorControlAction? {
    guard let angle, angle.isFinite else { return nil }
    let values = (properties["hw.sensor.posture_list"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
    let ranges = (properties["hw.sensor.hinge_angles_posture_definitions"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
    for (value, range) in zip(values, ranges) {
      let bounds = range.trimmingCharacters(in: .whitespaces).split(separator: "-")
      guard bounds.count == 2, let lower = Double(bounds[0]), let upper = Double(bounds[1]),
            angle >= lower, angle <= upper else { continue }
      switch Int(value.trimmingCharacters(in: .whitespaces)) {
      case 1: return .closed
      case 2: return .halfOpen
      case 3: return .open
      default: return nil
      }
    }
    return nil
  }
}

struct EmulatorDisplayMode: Codable {
  let action: EmulatorControlAction
  let width: Int
  let height: Int

  private static func primaryDisplay(in displayInfo: String) -> Substring? {
    displayInfo.split(whereSeparator: \.isNewline).first {
      $0.contains("DisplayDeviceInfo{") && $0.contains("address {port=0,")
    }
  }

  func isSupported(by displayInfo: String?) -> Bool {
    guard let displayInfo, let mainDisplay = Self.primaryDisplay(in: displayInfo) else { return true }
    // Newer system images can omit presets that remain in the AVD configuration.
    return mainDisplay.matches(of: /width=(\d+), height=(\d+)/).contains {
      Int($0.1) == width && Int($0.2) == height
    }
  }

  func matches(_ displaySize: String) -> Bool {
    // Folding remaps logical display 0 to the cover screen. The inner panel retains its preset.
    if let display = Self.primaryDisplay(in: displaySize),
       let match = display.firstMatch(of: /,\s(\d+) x (\d+), modeId\s/) {
      return Int(match.1) == width && Int(match.2) == height
    }
    guard let match = displaySize.firstMatch(of: /Physical size: (\d+)x(\d+)/),
          let currentWidth = Int(match.1), let currentHeight = Int(match.2) else { return false }
    return (width == currentWidth && height == currentHeight) || (width == currentHeight && height == currentWidth)
  }

  static func parse(_ configurations: String) -> [Self] {
    var seen: Set<Int> = []
    return configurations.split(separator: ",").compactMap { entry in
      let fields = entry.trimmingCharacters(in: .whitespaces).split(separator: "-")
      guard fields.count == 5, let id = Int(fields[1]),
            let action = EmulatorControlAction.allCases.first(where: { $0.displayModeID == id }),
            let width = Int(fields[2]), width > 0,
            let height = Int(fields[3]), height > 0,
            let density = Int(fields[4]), density > 0,
            seen.insert(id).inserted else { return nil }
      return Self(action: action, width: width, height: height)
    }
  }
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

/// Credentials stay in memory and are used only for the local emulator connection.
struct EmulatorGRPCEndpoint: Codable {
  let port: Int
  let token: String?
  var expiresAt: Date?

  static func isEmulator(_ deviceID: String) -> Bool {
    guard deviceID.hasPrefix("emulator-"),
          let port = UInt16(deviceID.dropFirst(9)) else { return false }
    return port >= 1024
  }
}
