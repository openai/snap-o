import AppKit
import Foundation
import SwiftUI

struct LiveCaptureView: View {
  @Environment(AppSettings.self)
  private var settings
  @Environment(\.appearsActive)
  private var appearsActive
  @Environment(\.scenePhase)
  private var scenePhase
  @Environment(\.livePreviewLoadingMessage)
  private var loadingMessage
  let fileStore: FileStore
  private let device: Device
  private let attachment: LivePreviewAttachment?
  @State private var viewID = UUID()

  init(device: Device, attachment: LivePreviewAttachment?, fileStore: FileStore) {
    self.device = device
    self.attachment = attachment
    self.fileStore = fileStore
  }

  private var focused: Bool {
    appearsActive && scenePhase == .active
  }

  private func updatePresentation(visible: Bool? = nil) {
    guard let attachment else { return }
    attachment.updatePresentation(
      viewID: viewID, visible: visible ?? attachment.isWindowVisible,
      focused: focused, syncClipboard: settings.syncClipboard
    )
  }

  var body: some View {
    if let fileDrop = attachment?.fileDrop {
      previewWithFileDrop(fileDrop)
    } else {
      previewContent
    }
  }

  private func previewWithFileDrop(_ fileDrop: DeviceFileDrop) -> some View {
    @Bindable var fileDrop = fileDrop
    return previewContent
      .dropDestination(for: URL.self, isEnabled: fileDrop.canAcceptDrop) { urls, _ in
        fileDrop.receive(urls)
      }
      .dropConfiguration { _ in DropConfiguration(operation: .copy) }
      .overlay(alignment: .bottom) {
        VStack(spacing: 0) {
          if fileDrop.isBusy || fileDrop.status != nil || !fileDrop.failures.isEmpty {
            DeviceFileDropStatus(model: fileDrop)
          }
          if let message = attachment?.preview?.keyboardError {
            HStack(spacing: 8) {
              Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button { attachment?.clearKeyboardError() } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Dismiss keyboard status")
            }
            .font(.callout)
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
          }
        }
      }
      .alert(fileDrop.installPrompt, isPresented: $fileDrop.asksToInstall) {
        Button("Install") { fileDrop.start(install: true) }
        Button("Copy to Downloads") { fileDrop.start(install: false) }
        Button("Cancel", role: .cancel) { fileDrop.pendingFiles = [] }
      } message: {
        if !fileDrop.installMessage.isEmpty { Text(fileDrop.installMessage) }
      }
      .alert(
        "“\(fileDrop.conflictName)” already exists",
        isPresented: $fileDrop.asksAboutConflict
      ) {
        Button("Keep Both") { fileDrop.answerConflict(.keepBoth) }
        Button("Replace", role: .destructive) { fileDrop.answerConflict(.replace) }
        Button("Skip", role: .cancel) { fileDrop.answerConflict(.skip) }
      }
  }

  private var previewContent: some View {
    ZStack {
      Color.clear
      if let attachment, let renderer = attachment.renderer(for: device, viewID: viewID) {
        LivePreviewRendererView(
          renderer: renderer,
          fileStore: fileStore,
          isVisible: attachment.isVideoVisible,
          thumbnail: attachment.thumbnail,
          keyboard: settings.keyboardInput ? attachment : nil
        ) { attachment.isMounted(viewID) }
        if attachment.isVideoVisible, attachment.thumbnail.displayedSessionID != renderer.session.id {
          waitingView(for: attachment)
        }
      } else if let attachment, let error = attachment.error {
        VStack(spacing: 8) {
          Text(error)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Connect") { attachment.retryVideo() }
        }
        .padding(16)
      } else if let attachment, !attachment.isClosed, attachment.isVideoVisible {
        waitingView(for: attachment)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      WindowVisibilityReader(forLivePreview: true) { visible in
        updatePresentation(visible: visible)
      }
      .frame(width: 0, height: 0)
    }
    .onChange(of: settings.syncClipboard) { updatePresentation() }
    .onChange(of: focused) { updatePresentation() }
    .onAppear {
      attachment?.mount(viewID)
      updatePresentation()
    }
    .onDisappear {
      attachment?.unmount(viewID)
    }
  }

  @ViewBuilder
  private func waitingView(for attachment: LivePreviewAttachment) -> some View {
    if let frame = attachment.thumbnail.lastPreviewFrame {
      ResumingPreviewView(frame: frame, hasLightCenter: attachment.thumbnail.lastPreviewFrameHasLightCenter)
    } else {
      WaitingForDeviceView(deviceMessage: loadingMessage(device.id))
    }
  }
}

struct ResumingPreviewView: View {
  let frame: CGImage
  let hasLightCenter: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var contrast

  var body: some View {
    ZStack {
      Image(decorative: frame, scale: 1)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .blur(radius: 10, opaque: true)
        .clipShape(Rectangle())
      Image("Aperture")
        .renderingMode(.template)
        .resizable()
        .foregroundStyle((hasLightCenter ? Color.black : .white).opacity(reduceTransparency || contrast == .increased ? 1 : 0.8))
        .frame(width: 64, height: 64)
        .infiniteRotate(duration: 2, animated: !reduceMotion)
        .shadow(color: (hasLightCenter ? Color.white : .black).opacity(contrast == .increased ? 0.85 : 0.58), radius: 1.5, y: 0.5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Resuming live preview")
    .allowsHitTesting(false)
  }
}
