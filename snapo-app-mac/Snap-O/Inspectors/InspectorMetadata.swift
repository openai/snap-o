import Foundation
import SnapODeviceClient

struct InspectorMetadata: Equatable {
  struct Process: Codable, Equatable {
    var name: String?
    var packageName: String?
    var processName: String?
    var iconBase64: String?
    var verifiedIdentity: InspectorProcessIdentity?
    var inspectors: [InspectorDescriptor] = []
  }

  var process = Process()
  private(set) var protocolVersion: Int?
  private(set) var compatibility: InspectorCompatibility = .unknown

  var needsLegacyProbe: Bool {
    compatibility == .unknown || compatibility == .missingDescriptor
  }

  var isLegacy: Bool {
    if case .legacy = compatibility { return true }
    return false
  }

  func descriptor(for kind: InspectorID) -> InspectorDescriptor? {
    process.inspectors.first { $0.id == kind }
  }

  mutating func updateProcessName(_ name: String) {
    process.processName = process.verifiedIdentity?.processName ?? name
  }

  mutating func invalidateVersion() {
    protocolVersion = nil
    compatibility = .unknown
  }

  @discardableResult
  mutating func applyPackageMetadata(_ record: InspectorProcessMetadata, kind: InspectorID) -> Bool {
    guard let app = record.app, let identity = InspectorProcessIdentity(metadata: record) else { return false }
    let sameProcess = process.verifiedIdentity == identity
    process = Process(
      name: app.name, packageName: app.packageName, processName: record.processName ?? process.processName,
      iconBase64: app.iconBase64, verifiedIdentity: identity, inspectors: app.inspectors
    )
    if let descriptor = descriptor(for: kind) {
      protocolVersion = descriptor.protocolVersion
      compatibility = descriptor.frontend.map {
        $0.hostApiVersion == 1 ? .supported : .hostAPI(version: $0.hostApiVersion)
      } ?? .missingFrontend(protocolVersion: descriptor.protocolVersion)
    } else if app.errors?.contains(where: { $0.key == "snapo.inspector." + kind.rawValue }) == true {
      protocolVersion = nil
      compatibility = .invalidDescriptor
    } else if !sameProcess || !isLegacy {
      protocolVersion = nil
      compatibility = .missingDescriptor
    }
    return true
  }

  @discardableResult
  mutating func applyLegacyMetadata(_ value: LegacyInspectorMetadata, kind: InspectorID) -> Bool {
    guard descriptor(for: kind) == nil, compatibility != .invalidDescriptor,
          process.verifiedIdentity.map({ $0.packageName == value.packageName }) ?? true,
          value.processName.map({ process.processName == nil || process.processName == $0 }) ?? true else { return false }
    process.name = process.name ?? value.name
    process.packageName = process.packageName ?? value.packageName
    process.processName = process.processName ?? value.processName
    protocolVersion = value.protocolVersion
    compatibility = .legacy(protocolVersion: value.protocolVersion)
    return true
  }
}
