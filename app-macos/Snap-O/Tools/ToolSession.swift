import Observation

@Observable
@MainActor
final class ToolSession {
  private(set) var model: ToolHostModel?

  @ObservationIgnored private let adbService: ADBService
  @ObservationIgnored private let deviceManager: DeviceManager
  @ObservationIgnored private var service: ToolService?

  init(adbService: ADBService, deviceManager: DeviceManager) {
    self.adbService = adbService
    self.deviceManager = deviceManager
  }

  func startIfNeeded() {
    guard model == nil else { return }
    let service = ToolService(adbService: adbService, deviceManager: deviceManager)
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
