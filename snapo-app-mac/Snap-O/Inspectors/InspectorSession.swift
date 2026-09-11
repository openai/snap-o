import Observation

@Observable
@MainActor
final class InspectorSession {
  private(set) var error: String?
  private(set) var model: InspectorHostModel?

  @ObservationIgnored private let adbService: ADBService
  @ObservationIgnored private let deviceTracker: DeviceTracker
  @ObservationIgnored private var service: InspectorService?

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    self.adbService = adbService
    self.deviceTracker = deviceTracker
  }

  func startIfNeeded() {
    guard model == nil else { return }
    let registry: InspectorPluginRegistry
    do { registry = try .bundled() } catch {
      self.error = error.localizedDescription
      return
    }
    error = nil
    let service = InspectorService(adbService: adbService, deviceTracker: deviceTracker, registry: registry)
    self.service = service
    model = InspectorHostModel(service: service)
  }

  func stop() async {
    model?.stop()
    model = nil
    guard let service else { return }
    self.service = nil
    await service.stop()
  }
}
