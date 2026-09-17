import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageCaptureView: View {
  let url: URL
  var onDelete: (() -> Void)?
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
        .focusedValue(\.captureImage, nsImage)
        .onTapGesture { isFocused = true }
        .onExitCommand { isFocused = false }
        .contextMenu {
          Button("Copy Image") {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([nsImage]) {
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
        .onDrag { dragItemProvider() }
        .onAppear { markPerfMilestones() }
    } else {
      Color.black
    }
  }

  private func saveImage() {
    let panel = NSSavePanel()
    panel.title = "Save Image As"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = url.lastPathComponent
    panel.directoryURL = SaveLocation.defaultDirectory(for: .image)
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    do {
      try Data(contentsOf: url).write(to: destination, options: .atomic)
      SaveLocation.setLastDirectoryURL(destination.deletingLastPathComponent(), for: .image)
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Unable to Save Image"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
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
    .onDrag { dragItemProvider() }
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

private func markPerfMilestones() {
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
