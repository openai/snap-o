import Combine

@MainActor
final class CaptureDeviceSelectionController: ObservableObject {
  let deviceStore: DeviceStore
  let devices = DeviceSelection()
  private var shouldPreserveSelection = false

  private var cancellables: Set<AnyCancellable> = []

  init(services: AppServices) {
    deviceStore = DeviceStore(tracker: services.deviceTracker)

    deviceStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    devices.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    deviceStore.$devices
      .sink { [weak self] devices in
        self?.onDevicesChanged(devices)
      }
      .store(in: &cancellables)

    onDevicesChanged(deviceStore.devices)
  }

  convenience init() {
    self.init(services: AppServices.shared)
  }

  var hasDevices: Bool { !devices.available.isEmpty }

  var isDeviceListInitialized: Bool { deviceStore.hasReceivedInitialDeviceList }

  func hasAlternativeDevice(comparedTo deviceID: String?) -> Bool {
    let candidates = devices.available
    guard !candidates.isEmpty else { return false }
    if let deviceID {
      return candidates.contains { $0.id != deviceID }
    }
    return candidates.count > 1
  }

  func start() async {
    await deviceStore.start()
  }

  func selectNextDevice() {
    if let nextID = deviceID(offsetFromCurrent: 1) {
      devices.selectedID = nextID
    }
  }

  func selectPreviousDevice() {
    if let previousID = deviceID(offsetFromCurrent: -1) {
      devices.selectedID = previousID
    }
  }

  func selectDevice(withID id: String?) {
    devices.selectedID = id
  }

  func handleDeviceUnavailable(currentDeviceID: String) {
    let available = devices.available
    if let alternative = available.first(where: { $0.id != currentDeviceID }) {
      devices.selectedID = alternative.id
    } else if let fallback = available.first {
      devices.selectedID = fallback.id
    } else {
      devices.selectedID = nil
    }
  }

  func updateShouldPreserveSelection(_ preserve: Bool) {
    guard shouldPreserveSelection != preserve else { return }
    shouldPreserveSelection = preserve
    onDevicesChanged(deviceStore.devices)
  }

  private func onDevicesChanged(_ list: [Device]) {
    devices.updateDevices(list, preserveSelectedIfMissing: shouldPreserveSelection)
  }

  private func deviceID(offsetFromCurrent offset: Int) -> String? {
    let available = devices.available
    guard !available.isEmpty else { return nil }

    guard
      let currentID = devices.selectedID,
      let currentIndex = available.firstIndex(where: { $0.id == currentID })
    else {
      return available.first?.id
    }

    let count = available.count
    var newIndex = (currentIndex + offset) % count
    if newIndex < 0 { newIndex += count }
    return available[newIndex].id
  }
}
