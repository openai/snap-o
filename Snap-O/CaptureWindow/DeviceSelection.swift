import Combine

@MainActor
final class DeviceSelection: ObservableObject {
  @Published var available: [Device] = []
  @Published var selectedID: String?

  var currentDevice: Device? {
    guard let id = selectedID else { return nil }
    return available.first { $0.id == id }
  }

  func updateDevices(_ list: [Device]) {
    available = list
    guard selectedID != nil else {
      selectedID = list.first?.id
      return
    }
    if !list.contains(where: { $0.id == selectedID }) {
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
