import Observation

@Observable
@MainActor
final class ToolSession {
  private(set) var model: ToolHostModel?

  @ObservationIgnored private let adbService: ADBService
  @ObservationIgnored private let deviceManager: DeviceManager
  @ObservationIgnored private var service: ToolService?
  @ObservationIgnored private var stopTask: Task<Void, Never>?

  init(adbService: ADBService, deviceManager: DeviceManager) {
    self.adbService = adbService
    self.deviceManager = deviceManager
  }

  func setVisible(_ visible: Bool) {
    guard stopTask == nil else { return }
    if visible {
      startIfNeeded()
    } else {
      model?.webContainer?.closeNativeColorPanel()
    }
  }

  func startIfNeeded() {
    guard model == nil, stopTask == nil else { return }
    let service = ToolService(adbService: adbService, deviceManager: deviceManager)
    self.service = service
    model = ToolHostModel(service: service)
  }

  func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    let modelCleanup = model?.stop()
    let service = service
    model = nil
    self.service = nil
    let task = Task {
      async let serviceCleanup = service?.stop()
      await modelCleanup?.value
      _ = await serviceCleanup
    }
    stopTask = task
    await task.value
  }
}
