import Foundation

public enum InspectorKind: String, Codable, Sendable {
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
  public let appIconBase64: String?

  public init(
    appName: String? = nil,
    processName: String? = nil,
    packageName: String? = nil,
    packageNameHint: String? = nil,
    appIconBase64: String? = nil
  ) {
    self.appName = Self.nonempty(appName)
    self.processName = Self.nonempty(processName)
    self.packageName = Self.nonempty(packageName)
    self.packageNameHint = Self.nonempty(packageNameHint)
    self.appIconBase64 = Self.nonempty(appIconBase64)
  }

  public func merging(_ other: Self) -> Self {
    Self(
      appName: appName ?? other.appName,
      processName: processName ?? other.processName,
      packageName: packageName ?? other.packageName,
      packageNameHint: packageNameHint ?? other.packageNameHint,
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

public enum InspectorDiscovery {
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
