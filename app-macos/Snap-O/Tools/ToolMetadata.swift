import Foundation

struct ToolMetadata: Equatable {
  struct Process: Codable, Equatable {
    var name: String?
    var packageName: String?
    var processName: String?
    var iconBase64: String?
    var verifiedIdentity: ToolProcessIdentity?
    var tools: [ToolDescriptor] = []
  }

  var process = Process()
  private(set) var compatibility: ToolCompatibility = .unknown

  var needsLegacyProbe: Bool {
    compatibility == .unknown || compatibility == .missingDescriptor
  }

  var isLegacy: Bool {
    if case .legacy = compatibility { return true }
    return false
  }

  func descriptor(for kind: ToolID) -> ToolDescriptor? {
    process.tools.first { $0.id == kind }
  }

  mutating func updateProcessName(_ name: String) {
    process.processName = process.verifiedIdentity?.processName ?? name
  }

  mutating func invalidateCompatibility() {
    compatibility = .unknown
  }

  @discardableResult
  mutating func applyPackageMetadata(_ record: ToolProcessMetadata, kind: ToolID) -> Bool {
    guard let app = record.app, let identity = ToolProcessIdentity(metadata: record) else { return false }
    let sameProcess = process.verifiedIdentity == identity
    process = Process(
      name: app.name, packageName: app.packageName, processName: record.processName ?? process.processName,
      iconBase64: app.iconBase64, verifiedIdentity: identity, tools: app.tools
    )
    if let descriptor = descriptor(for: kind) {
      compatibility = descriptor.frontend.map {
        $0.hostApiVersion == 2 ? .supported : .hostAPI(version: $0.hostApiVersion)
      } ?? .missingFrontend
    } else if app.errors?.contains(where: { $0.key == "snapo.inspector." + kind.rawValue }) == true {
      compatibility = .invalidDescriptor
    } else if !sameProcess || !isLegacy {
      compatibility = .missingDescriptor
    }
    return true
  }

  @discardableResult
  mutating func applyLegacyMetadata(_ value: LegacyPluginMetadata, kind: ToolID) -> Bool {
    guard descriptor(for: kind) == nil, compatibility != .invalidDescriptor,
          process.verifiedIdentity.map({ $0.packageName == value.packageName }) ?? true,
          value.processName.map({ process.processName == nil || process.processName == $0 }) ?? true else { return false }
    process.name = process.name ?? value.name
    process.packageName = process.packageName ?? value.packageName
    process.processName = process.processName ?? value.processName
    compatibility = .legacy(protocolVersion: value.protocolVersion)
    return true
  }
}
