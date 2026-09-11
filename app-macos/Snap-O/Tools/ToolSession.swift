import Observation

@Observable
@MainActor
final class ToolSession {
  private(set) var model: PluginHostModel?

  @ObservationIgnored private let adbService: ADBService
  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private var service: PluginService?

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func startIfNeeded() {
    guard model == nil else { return }
    let service = PluginService(adbService: adbService, deviceTracker: deviceTracker)
    self.service = service
    model = PluginHostModel(service: service)
  }

  func stop() async {
    model?.stop()
    model = nil
    guard let service else { return }
    self.service = nil
    await service.stop()
  }
}
