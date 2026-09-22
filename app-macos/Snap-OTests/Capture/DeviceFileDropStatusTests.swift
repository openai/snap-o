import AppKit
@testable import Snap_O
import SwiftUI
import Testing

@Suite("File transfer snackbar")
@MainActor
struct DeviceFileDropStatusTests {
  @Test("status stays compact in a tall preview", arguments: [320.0, 600.0])
  func compactLayout(width: Double) async throws {
    let device = Device(id: "synthetic", model: "Test phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
    let model = DeviceFileDrop(device: device)
    for state in ["progress", "error", "success"] {
      model.isBusy = state == "progress"
      model.progress = model.isBusy ? 0.4 : nil
      model.status = state == "progress" ? "Copying sample.png…" : "1 copied to Downloads"
      model.failures = state == "error" ? [String(repeating: "Detailed device error. ", count: 30)] : []
      model.failureSummary = "File transfers blocked by device policy"
      let host = NSHostingController(rootView: DeviceFileDropStatus(model: model))
      let size = host.sizeThatFits(in: NSSize(width: width, height: 900))
      #expect(size.height <= 110, "The snackbar must not expand to the preview height: \(state), \(size).")
      #expect(size.width <= min(width, 444))

      if let directory = ProcessInfo.processInfo.environment["SNAPO_RENDER_FILE_DROP_STATUS"], width == 600 {
        let preview = NSHostingView(rootView:
          Color(nsColor: .windowBackgroundColor)
            .overlay(alignment: .bottom) { DeviceFileDropStatus(model: model) }
            .frame(width: 520, height: 180)
        )
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
          styleMask: [.borderless],
          backing: .buffered,
          defer: false
        )
        window.contentView = preview
        defer { window.contentView = nil }
        preview.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("file-drop-\(state).png"))
      }
    }
  }
}
