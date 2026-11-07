import Foundation
import Observation

@Observable
@MainActor
final class ADBServers {
  private(set) var profiles: [RemoteADBServer]
  var configuredServerIDs: Set<ADBServerID> {
    Set([.local] + profiles.map { .remote($0.id) })
  }

  var deviceLinkServers: [ADBServerID: DeviceLinkConnection] {
    guard !stopped else { return [:] }
    var connections: [ADBServerID: DeviceLinkConnection] = [
      .local: linkConnection(id: .local, server: .local())
    ]
    for profile in profiles {
      switch profile.connection {
      case .ssh(let configuration):
        let id = ADBServerID.remote(profile.id)
        connections[id] = linkConnection(
          id: id,
          server: .ssh(destination: configuration.destination, port: configuration.port, adbPort: configuration.adbPort),
          isEnabled: profile.isEnabled
        )
      }
    }
    return connections
  }

  private func linkConnection(id: ADBServerID, server: DeviceLinkServer, isEnabled: Bool = true) -> DeviceLinkConnection {
    let snapshot = snapshots.first { $0.id == id }
    let isUpdating = updatingServerID.map { id == .remote($0) } ?? false
    return DeviceLinkConnection(
      server: server, isEnabled: isEnabled,
      state: isUpdating ? .unavailable("The server connection is being updated.") : snapshot?.state ?? .connecting,
      connectedSerials: snapshot?.inventory.connected.map { Set($0.map(\.serial)) }
    )
  }

  private(set) var snapshots: [ADBServerSnapshot] = []
  private(set) var updatingServerID: UUID?
  var isUpdating: Bool {
    updatingServerID != nil
  }

  var error: String?
  private let loadError: String?
  private let service: ADBService
  private let store: ADBServerStore
  private let makeTracker: (RemoteADBServer) -> any DeviceTracking
  private let updateLabels: ([ADBServerID: String]) -> Void
  private var observation: Task<Void, Never>?
  private var change: Task<Void, Error>?
  private var stopped = false

  init(
    service: ADBService, store: ADBServerStore, profiles: [RemoteADBServer], error: String? = nil,
    makeTracker: @escaping (RemoteADBServer) -> any DeviceTracking,
    updateLabels: @escaping ([ADBServerID: String]) -> Void
  ) {
    self.service = service
    self.store = store
    self.profiles = profiles
    self.error = error
    loadError = error
    self.makeTracker = makeTracker
    self.updateLabels = updateLabels
  }

  func start() {
    guard observation == nil, !stopped else { return }
    observation = Task {
      for await snapshots in await service.snapshots() {
        guard !Task.isCancelled else { return }
        self.snapshots = snapshots
      }
    }
  }

  func save(_ profile: RemoteADBServer) async throws {
    try profile.connection.validate()
    guard !profiles.contains(where: { $0.id != profile.id && $0.connection == profile.connection }) else {
      throw ADBError.protocolFailure("This SSH server is already in the list.")
    }
    var next = profiles
    if let index = next.firstIndex(where: { $0.id == profile.id }) {
      guard next[index] != profile else { return }
      next[index] = profile
    } else {
      next.append(profile)
    }
    try await apply(next, replacing: profile.id, tracker: profile.isEnabled ? makeTracker(profile) : nil)
  }

  func setEnabled(_ isEnabled: Bool, for profile: RemoteADBServer) async throws {
    guard var current = profiles.first(where: { $0.id == profile.id }) else { return }
    current.isEnabled = isEnabled
    try await save(current)
  }

  func remove(_ profile: RemoteADBServer) async throws {
    try await apply(profiles.filter { $0.id != profile.id }, replacing: profile.id, tracker: nil)
  }

  private func apply(_ next: [RemoteADBServer], replacing id: UUID, tracker: (any DeviceTracking)?) async throws {
    guard !stopped, !isUpdating else { throw CancellationError() }
    if let loadError { throw ADBError.parseFailure(loadError) }
    try store.save(next)
    profiles = next
    updateLabels(Dictionary(uniqueKeysWithValues: next.map { (.remote($0.id), $0.connection.displayAddress) }))
    updatingServerID = id
    let task = Task { try await service.replaceRemote(.remote(id), tracker: tracker) }
    change = task
    defer { updatingServerID = nil
      change = nil
    }
    try await task.value
  }

  func beginShutdown() {
    stopped = true
    observation?.cancel()
  }

  func stop() async {
    beginShutdown()
    await observation?.value
    _ = await change?.result
    observation = nil
  }
}
