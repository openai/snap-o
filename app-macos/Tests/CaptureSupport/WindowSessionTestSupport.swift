import Foundation
import Observation

extension DeviceManager {
  enum Entry { case emulator(ManagedEmulator) }
  var connectedDevices: [Device] {
    latestDevices
  }

  var entries: [Entry] {
    []
  }

  var hasLoaded: Bool {
    true
  }

  var isRefreshing: Bool {
    false
  }

  var matchingSerials: Set<String> {
    []
  }

  var loadError: String? {
    nil
  }

  var actions: [String: String] {
    [:]
  }

  var launchErrors: [String: String] {
    [:]
  }

  func start(_: ManagedEmulator) {}
}

actor CaptureHistoryRepository {
  private(set) var protections: [UUID: Set<UUID>] = [:]
  func protect(_ ids: Set<UUID>, owner: UUID) {
    guard !Task.isCancelled else { return }
    protections[owner] = ids.isEmpty ? nil : ids
    testChanges.signal()
  }
}

@MainActor
final class ToolService {
  private(set) var isStopped = false
  init(adbService: ADBService, deviceManager: DeviceManager) {}
  func stop() async {
    isStopped = true
  }
}

@MainActor
@Observable
final class ToolHostModel {
  let service: ToolService
  var webContainer: WebContainer?
  private(set) var isStopped = false
  init(service: ToolService) {
    self.service = service
  }

  func stop() {
    isStopped = true
  }
}

@MainActor
final class WebContainer {
  func closeNativeColorPanel() {}
}
