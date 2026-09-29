import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageCaptureView: View {
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
      _ = try CaptureCropExporter.exportImage(at: url, crop: crop, to: destination)
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

private struct CaptureFileDrag: ViewModifier {
  let isEnabled: Bool
  let provider: () -> NSItemProvider

  func body(content: Content) -> some View {
    if isEnabled {
      content.onDrag(provider)
    } else {
      content
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
