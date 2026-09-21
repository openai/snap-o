import SwiftUI

struct DeviceThumbnailView: View {
  let device: DeviceManagerEntry
  let action: String?
  let manager: DeviceManager
  @State private var screenshot = LivePreviewThumbnail()
  @State private var liveThumbnail: LivePreviewThumbnail?
  @Environment(\.displayScale)
  private var displayScale

  private var isBusy: Bool {
    action != nil || device.isTransitioning
  }

  var body: some View {
    ZStack {
      if device.isRunning, let image = liveThumbnail?.image ?? screenshot.image {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "iphone.gen3")
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(.secondary)
      }
      if device.isRunning, let liveThumbnail {
        DeviceThumbnailMirror(thumbnail: liveThumbnail)
          .allowsHitTesting(false)
      }
    }
    .frame(width: 40, height: 60)
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(alignment: .bottomTrailing) {
      if !isBusy, device.detail != nil {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
          .background(.background, in: Circle())
      } else if !isBusy, device.isRunning {
        Circle().fill(.green)
          .frame(width: 8, height: 8)
          .overlay { Circle().stroke(.background, lineWidth: 2) }
      }
    }
    .help(device.detail ?? action ?? device.status)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(action ?? device.status)
    .task(id: device.isRunning ? device.serial : nil) {
      liveThumbnail = nil
      screenshot = LivePreviewThumbnail()
      guard device.isRunning, let serial = device.serial else { return }
      let pixelSize = CGSize(width: 40 * displayScale, height: 60 * displayScale)
      while !Task.isCancelled {
        if let live = SnapOCommandCoordinator.shared.liveThumbnail(deviceID: serial) {
          live.cacheLiveFrame()
          liveThumbnail = live
        } else {
          await screenshot.refresh(pixelSize: pixelSize) { try await manager.screenshot(for: serial) }
          guard !Task.isCancelled else { return }
          liveThumbnail = nil
        }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
  }
}

private struct DeviceThumbnailMirror: NSViewRepresentable {
  let thumbnail: LivePreviewThumbnail

  func makeNSView(context: Context) -> LivePreviewThumbnailDisplayView {
    let view = LivePreviewThumbnailDisplayView()
    view.videoGravity = .resizeAspect
    return view
  }

  func updateNSView(_ view: LivePreviewThumbnailDisplayView, context: Context) {
    view.thumbnail = thumbnail
  }

  static func dismantleNSView(_ view: LivePreviewThumbnailDisplayView, coordinator: ()) {
    view.stop()
  }
}
