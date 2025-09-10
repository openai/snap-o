import Combine

enum DeviceTransitionDirection {
  case up
  case down
  case neutral
}

@MainActor
final class CaptureDeviceSelectionController: ObservableObject {
  let deviceStore: DeviceStore
  let devices = DeviceSelection()
  @Published private(set) var transitionDirection: DeviceTransitionDirection = .neutral
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
    guard let nextID = deviceID(offsetFromCurrent: 1) else { return }
    setSelectedDevice(id: nextID, direction: .down)
  }

  func selectPreviousDevice() {
    guard let previousID = deviceID(offsetFromCurrent: -1) else { return }
    setSelectedDevice(id: previousID, direction: .up)
  }

  func selectDevice(withID id: String?) {
    setSelectedDevice(id: id, direction: .neutral)
  }

  func handleDeviceUnavailable(currentDeviceID: String) {
    let available = devices.available
    let nextDevice = available.first { $0.id != currentDeviceID } ?? available.first
    setSelectedDevice(id: nextDevice?.id, direction: .neutral)
  }

  func updateShouldPreserveSelection(_ preserve: Bool) {
    guard shouldPreserveSelection != preserve else { return }
    shouldPreserveSelection = preserve
    onDevicesChanged(deviceStore.devices)
  }

  private func onDevicesChanged(_ list: [Device]) {
    let previousSelectedID = devices.selectedID
    let preserve = shouldPreserveSelection && previousSelectedID != nil
    devices.updateDevices(list, preserveSelectedIfMissing: preserve)

    if previousSelectedID == nil, devices.selectedID != nil {
      transitionDirection = .down
    } else if devices.selectedID == nil {
      transitionDirection = .neutral
    }
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

  private func setSelectedDevice(
    id: String?,
    direction: DeviceTransitionDirection
  ) {
    guard devices.selectedID != id else {
      transitionDirection = direction
      return
    }

    transitionDirection = direction

    Task { @MainActor in
      // Yielding ensures the transitions are updated before changing the view.
      await Task.yield()
      devices.selectedID = id
    }
  }
}
