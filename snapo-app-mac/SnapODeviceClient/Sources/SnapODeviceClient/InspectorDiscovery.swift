import Foundation

public enum InspectorKind: String, Codable, Sendable, CaseIterable {
  case network
  case tweaks

  public var socketPrefix: String {
    "snapo_\(rawValue)_"
  }

  public func pid(inSocketName socketName: String) -> Int? {
    guard socketName.hasPrefix(socketPrefix) else { return nil }
    let suffix = socketName.dropFirst(socketPrefix.count)
    guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
          let pid = Int(suffix), pid > 0 else { return nil }
    return pid
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
  public let kind: InspectorKind
  public let reference: NetworkServerReference
  public let deviceDisplayTitle: String
  public let protocolVersion: Int?
  public let metadata: InspectorAppMetadata

  public init(
    kind: InspectorKind,
    reference: NetworkServerReference,
    deviceDisplayTitle: String,
    protocolVersion: Int? = nil,
    metadata: InspectorAppMetadata = InspectorAppMetadata()
  ) {
    self.kind = kind
    self.reference = reference
    self.deviceDisplayTitle = deviceDisplayTitle
    self.protocolVersion = protocolVersion
    self.metadata = metadata
  }

  public var pid: Int? {
    kind.pid(inSocketName: reference.socketName)
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
  public let kind: InspectorKind
  public let reference: NetworkServerReference
}

public enum InspectorDiscovery {
  public static func sockets(inProcNetUnix output: String, deviceID: String) -> [DiscoveredInspectorSocket] {
    Set(output.split(separator: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).last })
      .sorted().compactMap { token in
        guard token.first == "@" else { return nil }
        let name = String(token.dropFirst())
        guard let kind = InspectorKind.allCases.first(where: { $0.pid(inSocketName: name) != nil }) else {
          return nil
        }
        return DiscoveredInspectorSocket(
          kind: kind,
          reference: NetworkServerReference(deviceId: deviceID, socketName: name)
        )
      }
  }

  public static func discover(on deviceIDs: [String], using adb: ADBClient) async -> [DiscoveredInspectorSocket] {
    await withTaskGroup(of: [DiscoveredInspectorSocket].self) { group in
      for deviceID in deviceIDs {
        group.addTask {
          guard let output = try? await adb.listUnixSockets(deviceID: deviceID) else { return [] }
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
        if $0.kind != $1.kind { return $0.kind == .network }
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
