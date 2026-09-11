import Foundation

public struct InspectorID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct InspectorAppMetadata: Sendable, Equatable {
  public let appName: String?
  public let processName: String?
  public let packageName: String?
  public let packageNameHint: String?
  public let androidUserID: Int?
  public let appIconBase64: String?

  public init(
    appName: String? = nil,
    processName: String? = nil,
    packageName: String? = nil,
    packageNameHint: String? = nil,
    androidUserID: Int? = nil,
    appIconBase64: String? = nil
  ) {
    self.appName = Self.nonempty(appName)
    self.processName = Self.nonempty(processName)
    self.packageName = Self.nonempty(packageName)
    self.packageNameHint = Self.nonempty(packageNameHint)
    self.androidUserID = androidUserID
    self.appIconBase64 = Self.nonempty(appIconBase64)
  }

  public func merging(_ other: Self) -> Self {
    Self(
      appName: appName ?? other.appName,
      processName: processName ?? other.processName,
      packageName: packageName ?? other.packageName,
      packageNameHint: packageNameHint ?? other.packageNameHint,
      androidUserID: androidUserID ?? other.androidUserID,
      appIconBase64: appIconBase64 ?? other.appIconBase64
    )
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }
}

public struct InspectorEndpoint: Sendable {
  public let kind: InspectorID
  public let pid: Int?
  public let reference: InspectorServerReference
  public let deviceDisplayTitle: String
  public let protocolVersion: Int?
  public let metadata: InspectorAppMetadata

  public init(
    kind: InspectorID,
    reference: InspectorServerReference,
    deviceDisplayTitle: String,
    pid: Int? = nil,
    protocolVersion: Int? = nil,
    metadata: InspectorAppMetadata = InspectorAppMetadata()
  ) {
    self.kind = kind
    self.pid = pid
    self.reference = reference
    self.deviceDisplayTitle = deviceDisplayTitle
    self.protocolVersion = protocolVersion
    self.metadata = metadata
  }

  public var processID: String {
    if let pid { return "\(reference.deviceId):pid:\(pid)" }
    return "\(reference.deviceId):socket:\(reference.socketName)"
  }
}

public struct InspectableProcess: Sendable {
  public let id: String
  public let pid: Int?
  public let deviceId: String
  public let deviceDisplayTitle: String
  public let metadata: InspectorAppMetadata
  public let inspectors: [InspectorEndpoint]

  public var name: String {
    metadata.appName ?? metadata.processName ?? metadata.packageName ?? metadata.packageNameHint
      ?? pid.map { "Process \($0)" } ?? inspectors[0].reference.socketName
  }
}

public struct DiscoveredInspectorSocket: Sendable, Equatable {
  public let kind: InspectorID
  public let pid: Int
  public let reference: InspectorServerReference
  public var inode: String?
  public var processName: String?
}

public enum InspectorDiscovery {
  static let processListMarker = "---snapo-processes---"
  static let snapshotCommand = """
  cat /proc/net/unix
  printf '\\n\(processListMarker)\\n'
  ps -A -o PID,NAME 2>/dev/null || ps
  """

  public static func sockets(
    inProcNetUnix output: String,
    deviceID: String
  ) -> [DiscoveredInspectorSocket] {
    let sections = output.components(separatedBy: "\n\(processListMarker)\n")
    let processNames = sections.count == 2 ? DeviceDiscovery.processNames(inProcessList: sections[1]) : [:]
    var seen: Set<String> = []
    return sections[0].split(separator: "\n").compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace)
      // Accepted and queued clients share the listener's name but have different inodes.
      guard fields.count == 8,
            let flags = UInt32(fields[3], radix: 16), flags & 0x0001_0000 != 0,
            fields[4] == "0001", fields[5] == "01",
            let inode = UInt64(fields[6]), inode > 0,
            let token = fields.last, token.first == "@" else { return nil }
      let name = String(token.dropFirst())
      guard name.range(of: #"^snapo_[a-z][a-z0-9.-]{0,99}_[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil,
            let separator = name.lastIndex(of: "_"),
            let pid = Int(name[name.index(after: separator)...]),
            seen.insert(name).inserted else { return nil }
      let id = String(name.dropFirst("snapo_".count).prefix(upTo: separator))
      return DiscoveredInspectorSocket(
        kind: InspectorID(rawValue: id),
        pid: pid,
        reference: InspectorServerReference(deviceId: deviceID, socketName: name),
        inode: String(inode),
        processName: processNames[pid]
      )
    }.sorted { $0.reference.identifier < $1.reference.identifier }
  }

  public static func discover(
    on deviceIDs: [String],
    using adb: ADBClient
  ) async -> [DiscoveredInspectorSocket] {
    await withTaskGroup(of: [DiscoveredInspectorSocket].self) { group in
      for deviceID in deviceIDs {
        group.addTask {
          guard let output = try? await adb.runDiscoveryShellString(deviceID: deviceID, command: snapshotCommand) else { return [] }
          return Self.sockets(inProcNetUnix: output, deviceID: deviceID)
        }
      }
      var sockets: [DiscoveredInspectorSocket] = []
      for await result in group {
        sockets.append(contentsOf: result)
      }
      return sockets.sorted { $0.reference.identifier < $1.reference.identifier }
    }
  }

  public static func processes(from endpoints: [InspectorEndpoint]) -> [InspectableProcess] {
    Dictionary(grouping: endpoints, by: \.processID).map { id, endpoints in
      let ordered = endpoints.sorted {
        if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
        return $0.reference.socketName < $1.reference.socketName
      }
      let first = ordered[0]
      let metadata = ordered.reduce(InspectorAppMetadata()) { $0.merging($1.metadata) }
      return InspectableProcess(
        id: id,
        pid: first.pid,
        deviceId: first.reference.deviceId,
        deviceDisplayTitle: first.deviceDisplayTitle,
        metadata: metadata,
        inspectors: ordered
      )
    }.sorted { $0.id < $1.id }
  }
}
