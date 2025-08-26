import Observation

@MainActor
@Observable
final class DeviceListViewModel {
  var devices: [Device] = []
  var selectedDeviceID: String?

  var currentDevice: Device? {
    guard let id = selectedDeviceID else { return nil }
    return devices.first { $0.id == id }
  }

  func onDevicesChanged(_ list: [Device]) {
    devices = list
    // Keep selection stable by ID if possible; else pick first.
    if let sel = selectedDeviceID,
       list.contains(where: { $0.id == sel }) {
      // keep selectedDeviceID
    } else {
      selectedDeviceID = list.first?.id
    }
  }

  // MARK: Navigation

  private var currentIndex: Int? {
    guard let id = selectedDeviceID else { return nil }
    return devices.firstIndex { $0.id == id }
  }

  func selectNextDevice() {
    guard !devices.isEmpty else { selectedDeviceID = nil
      return
    }
    guard let idx = currentIndex else { selectedDeviceID = devices.first?.id
      return
    }
    selectedDeviceID = devices[(idx + 1) % devices.count].id
  }

  func selectPreviousDevice() {
    guard !devices.isEmpty else { selectedDeviceID = nil
      return
    }
    guard let idx = currentIndex else { selectedDeviceID = devices.first?.id
      return
    }
    selectedDeviceID = devices[(idx - 1 + devices.count) % devices.count].id
  }
}
