import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageCaptureView: View {
  let fileStore: FileStore
  let url: URL
  var exportFilename: String?
  var onDelete: (() -> Void)?
  var allowsFileDrag = true
  var crop = CaptureCropGeometry.fullImage
  var makeTempDragFile: () -> URL?

  @Environment(\.captureImageCopied)
  private var imageCopied
  @State private var loader = ImageLoader()
  @FocusState private var isFocused: Bool

  var body: some View {
    if let nsImage = loader.image(url: url) {
      Image(nsImage: nsImage)
        .resizable()
        .scaledToFill()
        .clipped()
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .focusedValue(\.captureImage, croppedImage(nsImage))
        .onTapGesture { isFocused = true }
        .onExitCommand { isFocused = false }
        .contextMenu {
          Button("Copy Image") {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([croppedImage(nsImage)]) {
              imageCopied()
            }
          }
          Button("Save Image As…") { saveImage() }
          if let onDelete {
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
          }
        }
        .accessibilityLabel("Screenshot")
        .modifier(CaptureFileDrag(isEnabled: allowsFileDrag, provider: dragItemProvider))
        .onAppear { markPerfMilestones() }
        .onChange(of: crop) { if !allowsFileDrag { isFocused = true } }
    } else {
      Color.black
    }
  }

  private func saveImage() {
    let panel = NSSavePanel()
    panel.title = "Save Image As"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = exportFilename ?? url.lastPathComponent
    panel.directoryURL = SaveLocation.defaultDirectory(for: .image)
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    do {
      try fileStore.saveImage(at: url, crop: crop, to: destination)
      SaveLocation.setLastDirectoryURL(destination.deletingLastPathComponent(), for: .image)
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Unable to Save Image"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  private func croppedImage(_ original: NSImage) -> NSImage {
    guard crop != CaptureCropGeometry.fullImage,
          let image = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let cropped = image.cropping(to: CaptureCropExporter.pixelRect(crop, size: CGSize(width: image.width, height: image.height)))
    else {
      return original
    }
    return NSImage(cgImage: cropped, size: CGSize(width: cropped.width, height: cropped.height))
  }

  private func dragItemProvider() -> NSItemProvider {
    if let url = makeTempDragFile() {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}

struct VideoCaptureView: View {
  let url: URL
  var onFocusChange: (Bool) -> Void = { _ in }
  var onDelete: (() -> Void)?
  var allowsFileDrag = true
  var makeTempDragFile: () -> URL?

  var body: some View {
    ZStack {
      VideoLoopingView(url: url, onFocusChange: onFocusChange)
      Color.gray.opacity(0.01)
        .padding([.bottom], 40)
    }
    .clipped()
    .contextMenu {
      if let onDelete {
        Button("Delete…", role: .destructive, action: onDelete)
      }
    }
    .modifier(CaptureFileDrag(isEnabled: allowsFileDrag, provider: dragItemProvider))
    .onAppear { markPerfMilestones() }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func dragItemProvider() -> NSItemProvider {
    if let url = makeTempDragFile() {
      NSItemProvider(object: url as NSURL)
    } else {
      NSItemProvider()
    }
  }
}

@MainActor
final class MediaDragWindow {
  private weak var draggedWindow: NSWindow?
  private var originalLevel = NSWindow.Level.normal
  private var windowAbove: Int?
  private var windowBelow: Int?

  func sendBehindApps(_ window: NSWindow?) {
    guard let window, draggedWindow == nil else { return }
    draggedWindow = window
    originalLevel = window.level
    let peers = visibleWindowNumbers(at: originalLevel)
    if let index = peers.firstIndex(of: window.windowNumber) {
      windowAbove = peers[..<index].last
      windowBelow = peers.dropFirst(index + 1).first
    }
    window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    window.orderBack(nil)
  }

  func restore() {
    defer {
      draggedWindow = nil
      windowAbove = nil
      windowBelow = nil
    }
    guard let window = draggedWindow else { return }
    window.level = originalLevel
    let peers = visibleWindowNumbers(at: originalLevel)
    if let windowAbove, peers.contains(windowAbove) {
      window.order(.below, relativeTo: windowAbove)
    } else if let windowBelow, peers.contains(windowBelow) {
      window.order(.above, relativeTo: windowBelow)
    } else {
      window.orderFront(nil)
    }
  }

  private func visibleWindowNumbers(at level: NSWindow.Level) -> [Int] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    return (windows as? [[String: Any]] ?? []).compactMap { info in
      guard info[kCGWindowLayer as String] as? Int == level.rawValue else { return nil }
      return info[kCGWindowNumber as String] as? Int
    }
  }
}

private struct CaptureFileDrag: ViewModifier {
  let isEnabled: Bool
  @State private var dragWindow = MediaDragWindow()
  let provider: () -> NSItemProvider

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .onDrag {
          let item = provider()
          if !item.registeredTypeIdentifiers.isEmpty {
            dragWindow.sendBehindApps(NSApp.currentEvent?.window)
          }
          return item
        }
        .onDragSessionUpdated { session in
          if case .ended = session.phase { dragWindow.restore() }
        }
    } else {
      content
    }
  }
}

func markPerfMilestones() {
  Perf.end(.captureRequest, finalLabel: "snapshot rendered")
  Perf.end(.recordingRender, finalLabel: "video rendered")
  Perf.end(.appFirstSnapshot, finalLabel: "first media appeared")
}

@MainActor
final class ImageLoader {
  private var image: NSImage?
  private var url: URL?

  func image(url: URL) -> NSImage? {
    guard url != self.url else { return image }
    self.url = url
    let nsImage = NSImage(contentsOf: url)
    image = nsImage
    return nsImage
  }
}
