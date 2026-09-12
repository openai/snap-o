import Observation

@Observable
@MainActor
final class ToolSession {
  private(set) var model: ToolHostModel?

  @ObservationIgnored private let adbService: ADBService
  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private var service: ToolService?

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func startIfNeeded() {
    guard model == nil else { return }
    let service = ToolService(adbService: adbService, deviceTracker: deviceTracker)
    self.service = service
    model = ToolHostModel(service: service)
  }

  func stop() async {
    model?.stop()
    model = nil
    guard let service else { return }
    self.service = nil
    await service.stop()
  }
}
