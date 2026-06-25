import Observation

@Observable
@MainActor
final class NetworkInspectorSession {
  private(set) var model: NetworkInspectorHostModel?

  @ObservationIgnored private let adbService: ADBService
  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private var service: NetworkInspectorService?

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func startIfNeeded() {
    guard model == nil else { return }
    let service = NetworkInspectorService(adbService: adbService, deviceTracker: deviceTracker)
    self.service = service
    model = NetworkInspectorHostModel(service: service)
  }

  func stop() async {
    model?.stop()
    model = nil
    guard let service else { return }
    self.service = nil
    await service.stop()
  }
}
