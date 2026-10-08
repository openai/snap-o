import SwiftUI

struct CaptureReviewView: View {
  @Bindable var review: CaptureReviewState
  let returnToLive: () -> Void
  @State private var isNaming = false
  @State private var isConfirmingDiscard = false
  @State private var trimFieldsValid = true

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Color.clear
        content(in: geometry.size)
        Group {
          if review.playback.isTrimming {
            CaptureTrimToolbar(canApply: trimFieldsValid) {
              review.playback.cancelTrimming()
            } apply: {
              review.setTrim(review.playback.confirmTrim())
            }
          } else {
            toolbar
          }
        }
        .frame(height: CaptureReviewLayout.toolbarHeight)
        .padding(.horizontal, CaptureReviewLayout.edgeSpacing)
        .padding(.vertical, CaptureReviewLayout.toolbarSpacing)
      }
    }
    .overlay { CaptureCopyConfirmation(copyID: review.imageCopyID) }
    .background(CaptureSheetAnchor(isPresented: isNaming || isConfirmingDiscard))
    .captureReviewKeyboard(onExit: handleEscape)
    .alert("Discard \(mediaName)?", isPresented: $isConfirmingDiscard) {
      Button("Keep Editing", role: .cancel) {}
      Button("Discard", role: .destructive, action: returnToLive)
        .keyboardShortcut(.defaultAction)
    } message: {
      Text("This will return to Live Preview without saving to Capture History.")
    }
    .sheet(isPresented: $isNaming) {
      CaptureSaveSheet { name in
        try await review.saveToHistory(name: name)
        isNaming = false
        returnToLive()
      }
    }
    .alert("Capture Error", isPresented: Binding(
      get: { review.errorMessage != nil && !isNaming },
      set: { if !$0 { review.clearError() } }
    )) {
      Button("OK") { review.clearError() }
    } message: {
      Text(review.errorMessage ?? "")
    }
  }

  @ViewBuilder
  private func content(in size: CGSize) -> some View {
    if let capture = review.currentCapture {
      let frame = CaptureReviewLayout.mediaFrame(
        in: size, aspectRatio: capture.media.aspectRatio,
        showsPlayback: capture.media.isVideo, isTrimming: review.playback.isTrimming
      )
      let request = try? review.exportRequest()
      ZStack(alignment: .topLeading) {
        if case .video(let url, _) = capture.media {
          CaptureReviewVideo(
            url: url, mediaFrame: frame,
            controlsFrame: CaptureReviewLayout.playbackFrame(in: size, isTrimming: review.playback.isTrimming),
            playback: review.playback, trim: review.trim,
            load: { await review.loadPlayback() },
            onTrimValidityChange: { trimFieldsValid = $0 }
          )
        } else if case .image(let url, _) = capture.media {
          ImageCaptureView(
            fileStore: review.fileStore, url: url,
            exportFilename: FileStore.exportFilename(
              capturedAt: capture.media.capturedAt, kind: .image
            ),
            allowsFileDrag: false, crop: review.crop
          ) { nil }
            .id(capture.id)
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .position(x: frame.midX, y: frame.midY)
        }
        CaptureCropOverlay(
          imageFrame: frame,
          crop: Binding(
            get: { review.crop },
            set: { review.setCrop($0) }
          ),
          isEnabled: !review.playback.isTrimming && !isNaming && !review.isClosing && !review.isSaving,
          allowsFileDrag: !capture.media.isVideo || request.map { review.dragExport.isReady(for: $0) } == true
        ) { try? review.makeDragItem(frame: $0) }
          .id(capture.id)
      }
      .task(id: request) { await review.prepareDrag() }
    } else {
      VStack(spacing: 12) {
        switch review.operation.state {
        case .failed(let message):
          Image(systemName: "exclamationmark.triangle").font(.title2)
          Text(message).multilineTextAlignment(.center).textSelection(.enabled)
        case .cancelled:
          Text("Capture cancelled")
        default:
          Image("Aperture")
            .renderingMode(.template)
            .resizable()
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 64)
            .infiniteRotate(animated: true)
            .accessibilityLabel(review.operation.kind == .recording ? "Preparing recording" : "Taking screenshot")
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var mediaName: String {
    review.operation.kind == .recording ? "Recording" : "Screenshot"
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Button(action: returnToLive) {
        Image(systemName: "xmark")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .glassEffect(.regular.interactive(), in: Circle())
      .help("Discard \(mediaName)")
      .accessibilityLabel("Discard \(mediaName)")

      Spacer(minLength: 0)

      if let warning = review.operation.warning {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .help(warning)
          .accessibilityLabel(warning)
      }

      if review.dragExport.isPreparing {
        ProgressView().controlSize(.small)
          .help("Preparing recording for dragging")
          .accessibilityLabel("Preparing recording for dragging")
      }
      if let error = review.dragExport.errorMessage {
        Image(systemName: "exclamationmark.triangle")
          .help(error)
          .accessibilityLabel(error)
      }

      if review.currentCapture?.media.isVideo == true {
        Button {
          trimFieldsValid = true
          review.playback.beginTrimming()
        } label: {
          Image(systemName: "scissors")
            .font(SnapOToolbarStyle.iconFont)
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(!review.playback.canTrim)
        .help("Trim Recording")
        .accessibilityLabel("Trim Recording")
      }

      Button { isNaming = true } label: {
        Image(systemName: "checkmark")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.white)
      .glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
      .disabled(review.operation.isComplete && review.currentCapture == nil)
      .help("Save \(mediaName) to History")
      .accessibilityLabel("Save \(mediaName) to History")
    }
    .disabled(review.isClosing || review.isSaving)
  }

  private func handleEscape() {
    switch CaptureReviewEscapeAction(
      isNaming: isNaming, isSaving: review.isSaving, isClosing: review.isClosing,
      hasError: review.errorMessage != nil, isTrimming: review.playback.isTrimming
    ) {
    case .ignore:
      break
    case .cancelTrim:
      review.playback.cancelTrimming()
    case .confirmDiscard:
      isConfirmingDiscard = true
    }
  }
}
