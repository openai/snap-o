import SwiftUI

struct CaptureDeviceOption: Identifiable {
  let id: String
  let title: String
  let status: String?
  let serial: String?
  let request: DeviceOpenRequest

  init?(entry: DeviceManagerEntry, startupStatus: String?) {
    switch entry {
    case .connected(let device):
      request = .serial(device.id)
    case .emulator(let device):
      guard startupStatus != "Deleting", device.state != .stopping,
            device.state == .running || device.state == .starting || device.state == .offline || startupStatus == "Starting"
      else { return nil }
      request = .avd(device.avdName, start: false)
    }
    id = entry.id
    title = entry.title
    serial = entry.serial
    status = startupStatus
  }

  func matches(_ selection: DeviceOpenRequest?) -> Bool {
    switch selection {
    case .serial(let selectedSerial):
      return serial == selectedSerial
    case .avd(let name, _):
      guard case .avd(let avdName, _) = request else { return false }
      return avdName == name
    case nil:
      return false
    }
  }
}

struct CaptureDevicePicker: View {
  let devices: [CaptureDeviceOption]
  let selection: DeviceOpenRequest?
  let select: (DeviceOpenRequest) -> Void

  private var selectedIndex: Int? {
    devices.firstIndex { $0.matches(selection) }
  }

  var body: some View {
    Menu {
      Picker("Device", selection: Binding<String?>(
        get: { selectedIndex.map { devices[$0].id } },
        set: { id in
          if let device = devices.first(where: { $0.id == id }) { select(device.request) }
        }
      )) {
        ForEach(devices) { device in
          Text(device.status.map { "\(device.title) (\($0))" } ?? device.title)
            .tag(Optional(device.id))
        }
      }
    } label: {
      CaptureSelectionPill(position: selectedIndex.map { "\($0 + 1)/\(devices.count)" } ?? "Devices")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Choose a device")
    .accessibilityLabel("Device")
  }
}
