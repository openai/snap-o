import Combine

@MainActor
final class DeviceSelection: ObservableObject {
  @Published var available: [Device] = []
  @Published var selectedID: String? {
    didSet {
      guard selectedID != oldValue else { return }
      cachedSelectedDevice =
        selectedID.flatMap { id in available.first { $0.id == id } } ?? cachedSelectedDevice
      if selectedID == nil {
        cachedSelectedDevice = nil
      }
    }
  }

  private var cachedSelectedDevice: Device?

  var currentDevice: Device? {
    guard let id = selectedID else { return nil }
    if let live = available.first(where: { $0.id == id }) {
      cachedSelectedDevice = live
      return live
    }
    return cachedSelectedDevice
  }

  func updateDevices(_ list: [Device], preserveSelectedIfMissing: Bool) {
    available = list

    if let selectedID, let live = list.first(where: { $0.id == selectedID }) {
      cachedSelectedDevice = live
    } else if selectedID == nil || !preserveSelectedIfMissing {
      selectedID = list.first?.id
    }
  }

  func selectNext() {
    guard !available.isEmpty else {
      selectedID = nil
      return
    }
    guard let idx = currentIndex else {
      selectedID = available.first?.id
      return
    }
    selectedID = available[(idx + 1) % available.count].id
  }

  func selectPrevious() {
    guard !available.isEmpty else {
      selectedID = nil
      return
    }
    guard let idx = currentIndex else {
      selectedID = available.first?.id
      return
    }
    selectedID = available[(idx - 1 + available.count) % available.count].id
  }

  // MARK: - Helpers

  private var currentIndex: Int? {
    guard let id = selectedID else { return nil }
    return available.firstIndex { $0.id == id }
  }
}
