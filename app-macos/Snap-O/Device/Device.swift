import Foundation

/// An Android device discovered through the host ADB server.
public struct Device: Identifiable, Hashable, Sendable {
  public let id: String
  public let identity: DeviceID
  public var serial: String {
    identity.serial
  }

  var isLocalEmulator: Bool {
    identity.isLocalEmulator
  }

  public let model: String
  public let androidVersion: String
  public let vendorModel: String?
  public let manufacturer: String?
  public let avdName: String?
  public let displayName: String?
  public let transportID: String?
  public let connection: DeviceTarget?

  public init(
    id: String,
    model: String,
    androidVersion: String,
    vendorModel: String?,
    manufacturer: String?,
    avdName: String?,
    displayName: String? = nil,
    transportID: String? = nil,
    connection: DeviceTarget? = nil
  ) {
    identity = connection?.deviceID ?? DeviceID(storedValue: id)
    self.id = identity.storedValue
    self.model = model
    self.androidVersion = androidVersion
    self.vendorModel = vendorModel
    self.manufacturer = manufacturer
    self.avdName = avdName
    self.displayName = displayName
    self.transportID = transportID
    self.connection = connection
  }

  func requireConnection() throws -> DeviceTarget {
    guard let connection else {
      throw ADBError.protocolFailure("The device connection is no longer available.")
    }
    _ = try connection.requireTransport(for: serial)
    return connection
  }
}

/// Each list stays nil until discovery has reported its first result.
struct DeviceInventory: Equatable {
  var connected: [Device]?
  var ready: [Device]?
}

public enum ADBError: Error, LocalizedError, Sendable {
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

/// The ADB server connection used to discover these device connections.
protocol DeviceServerConnection: AnyObject, Sendable {
  var id: UUID { get }
  var serverID: ADBServerID { get }
  func makeOperationConnection() throws -> any ADBConnection
  func register(_ target: DeviceTarget)
  func verifyConnection(selecting: () throws -> Void) throws
}

/// Identifies one device connection, even when its serial is reused.
public final class DeviceTarget: Hashable, @unchecked Sendable {
  public let id = UUID()
  public let serial: String
  public var deviceID: DeviceID {
    DeviceID(serverID: server?.serverID ?? .local, serial: serial)
  }

  var isLocalEmulator: Bool {
    deviceID.isLocalEmulator
  }

  public let transportID: String?
  let server: (any DeviceServerConnection)?
  private let lock = NSLock()
  private var valid = true
  private var invalidationHandlers: [UUID: () -> Void] = [:]

  init(serial: String, transportID: String?, server: (any DeviceServerConnection)? = nil) {
    self.serial = serial
    self.transportID = transportID
    self.server = server
    server?.register(self)
  }

  func selectTransport(for serial: String, selecting: (String) throws -> Void) throws {
    let transportID = try requireTransport(for: serial)
    if let server {
      try server.verifyConnection { try selecting(transportID) }
    } else {
      try selecting(transportID)
    }
    _ = try requireTransport(for: serial)
  }

  public static func == (lhs: DeviceTarget, rhs: DeviceTarget) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  var isValid: Bool {
    lock.withLock { valid }
  }

  func requireTransport(for serial: String) throws -> String {
    try lock.withLock {
      guard valid, self.serial == serial else {
        throw ADBError.protocolFailure("The device connection is no longer available.")
      }
      guard let transportID, let number = UInt64(transportID), number > 0 else {
        throw ADBError.protocolFailure("ADB did not provide a transport ID for this device. Reconnect it and try again.")
      }
      return transportID
    }
  }

  func onInvalidation(_ handler: @escaping () -> Void) throws -> UUID {
    try lock.withLock {
      guard valid else { throw ADBError.protocolFailure("The device connection is no longer available.") }
      let id = UUID()
      invalidationHandlers[id] = handler
      return id
    }
  }

  func removeInvalidationHandler(_ id: UUID) {
    _ = lock.withLock { invalidationHandlers.removeValue(forKey: id) }
  }

  func invalidate() {
    let handlers = lock.withLock {
      valid = false
      let handlers = Array(invalidationHandlers.values)
      invalidationHandlers.removeAll()
      return handlers
    }
    for handler in handlers {
      handler()
    }
  }
}

/// Stable identity for a configured server, independent of its live connection.
public enum ADBServerID: Hashable, Codable, Sendable {
  case local
  case remote(UUID)
}

public struct DeviceID: Hashable, Codable, Sendable {
  public let serverID: ADBServerID
  public let serial: String
  private static let prefix = "snapo-adb:"

  public init(serverID: ADBServerID, serial: String) {
    self.serverID = serverID
    self.serial = serial
  }

  var isLocalEmulator: Bool {
    serverID == .local && serial.hasPrefix("emulator-")
      && UInt16(serial.dropFirst("emulator-".count)).map { $0 >= 1024 } == true
  }

  /// Existing local selections and capture history retain their original keys.
  var storedValue: String {
    if serverID == .local, !serial.hasPrefix(Self.prefix) { return serial }
    let server: String = switch serverID {
    case .local: "local"
    case .remote(let id): id.uuidString.lowercased()
    }
    return Self.prefix + server + ":" + Data(serial.utf8).base64EncodedString()
  }

  init(storedValue: String) {
    let parts = storedValue.dropFirst(Self.prefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    if storedValue.hasPrefix(Self.prefix), parts.count == 2,
       let data = Data(base64Encoded: String(parts[1])), let serial = String(data: data, encoding: .utf8),
       parts[0] == "local" || UUID(uuidString: String(parts[0])) != nil {
      serverID = UUID(uuidString: String(parts[0])).map(ADBServerID.remote) ?? .local
      self.serial = serial
    } else {
      serverID = .local
      serial = storedValue
    }
  }
}
