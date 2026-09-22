import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@Suite("File transfer snackbar")
@MainActor
struct DeviceFileDropStatusTests {
  @Test("status stays compact in a tall preview", arguments: [320.0, 600.0])
  func compactLayout(width: Double) {
    let device = Device(id: "synthetic", model: "Test phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
    let model = DeviceFileDrop(device: device)
    for state in ["progress", "error", "success"] {
      model.isBusy = state == "progress"
      model.progress = model.isBusy ? 0.4 : nil
      model.status = state == "progress" ? "Copying sample.png…" : "1 copied to Downloads"
      model.failures = state == "error" ? [DeviceFileDrop.Failure(
        message: "File transfers blocked by device policy", details: nil
      )] : []
      let host = NSHostingController(rootView: DeviceFileDropStatus(model: model))
      let size = host.sizeThatFits(in: NSSize(width: width, height: 900))
      #expect(size.height <= 110, "The snackbar must not expand to the preview height: \(state), \(size).")
      #expect(size.width <= min(width, 444))
    }
  }
}
