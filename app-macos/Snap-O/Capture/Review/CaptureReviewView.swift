import SwiftUI

struct CaptureReviewView: View {
  @Environment(CaptureHistory.self)
  private var history
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
              if let id = review.selectedItemID {
                review.setTrim(review.playback.confirmTrim(), for: id)
              }
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
    .background(CaptureReviewFocus(onExit: handleEscape))
    .onKeyPress(.escape) {
      handleEscape()
      return .handled
    }
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
    if let item = review.selectedItem, let capture = item.media {
      let frame = CaptureReviewLayout.mediaFrame(
        in: size, aspectRatio: capture.media.aspectRatio,
        showsPlayback: capture.media.isVideo, isTrimming: review.playback.isTrimming
      )
      let request = try? review.exportRequest(for: item.id)
      ZStack(alignment: .topLeading) {
        if case .video(let url, _) = capture.media {
          CaptureReviewVideo(
            url: url, mediaFrame: frame,
            controlsFrame: CaptureReviewLayout.playbackFrame(in: size, isTrimming: review.playback.isTrimming),
            playback: review.playback, trim: review.trim(for: item.id),
            load: { await review.loadPlayback(for: item.id) },
            onTrimValidityChange: { trimFieldsValid = $0 }
          )
        } else if case .image(let url, _) = capture.media {
          ImageCaptureView(
            fileStore: review.fileStore, url: url,
            exportFilename: FileStore.exportFilename(
              capturedAt: capture.media.capturedAt, kind: .image, name: history.name(for: capture.id)
            ),
            allowsFileDrag: false, crop: review.crop(for: item.id)
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
            get: { review.crop(for: item.id) },
            set: { review.setCrop($0, for: item.id) }
          ),
          isEnabled: !review.playback.isTrimming && !isNaming && !review.isClosing && !review.isSaving,
          allowsFileDrag: !capture.media.isVideo || request.map { review.dragExport.isReady(for: $0) } == true
        ) { try? review.makeDragItem(for: item.id, frame: $0) }
          .id(item.id)
      }
      .task(id: request) { await review.prepareDrag(for: item.id) }
    } else if let item = review.selectedItem {
      VStack(spacing: 12) {
        switch item.state {
        case .failed(let message):
          Image(systemName: "exclamationmark.triangle").font(.title2)
          Text(message).multilineTextAlignment(.center).textSelection(.enabled)
        case .cancelled:
          Text("Capture cancelled")
        default:
          ProgressView()
          Text(review.batch.kind == .recording ? "Preparing recording" : "Taking screenshot")
        }
        Text(item.device.displayTitle).foregroundStyle(.secondary)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var mediaName: String {
    if review.batch.kind == .recording { return review.items.count > 1 ? "Recordings" : "Recording" }
    return review.items.count > 1 ? "Screenshots" : "Screenshot"
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

      if review.items.count > 1 {
        ReviewItemStrip(items: review.items, selectedID: review.selectedItemID, select: review.select)
      } else {
        Spacer(minLength: 0)
      }

      if let warning = review.selectedItem?.warning {
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
      .disabled(review.batch.isComplete && review.mediaList.isEmpty)
      .help("Save \(mediaName) to History")
      .accessibilityLabel("Save \(mediaName) to History")
    }
    .disabled(review.isClosing || review.isSaving)
  }

  private func handleEscape() {
    guard !isNaming, !review.isSaving, !review.isClosing, review.errorMessage == nil else { return }
    if review.playback.isTrimming {
      review.playback.cancelTrimming()
    } else {
      isConfirmingDiscard = true
    }
  }
}

private struct ReviewItemStrip: View {
  let items: [CaptureItem]
  let selectedID: UUID?
  let select: (UUID) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(items) { item in
            Button { select(item.id) } label: {
              ReviewItemThumbnail(item: item)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                  RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(item.id == selectedID ? Color.accentColor : .clear, lineWidth: 2)
                }
            }
            .buttonStyle(.plain)
            .help(item.device.displayTitle)
            .accessibilityLabel(item.device.displayTitle)
            .accessibilityAddTraits(item.id == selectedID ? .isSelected : [])
            .id(item.id)
          }
        }
        .padding(2)
      }
      .scrollIndicators(.hidden)
      .defaultScrollAnchor(.center, for: .alignment)
      .onChange(of: selectedID, initial: true) {
        if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct ReviewItemThumbnail: View {
  let item: CaptureItem
  @State private var imageLoader = ImageLoader()

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        switch item.state {
        case .ready(let capture, _):
          if case .image(let url, _) = capture.media, let image = imageLoader.image(url: url) {
            Image(nsImage: image).resizable().scaledToFill()
          } else if case .video(let url, _) = capture.media {
            VideoPreviewThumbnail(url: url)
          }
        case .failed:
          Image(systemName: "exclamationmark.triangle").accessibilityLabel("Capture failed")
        case .cancelled:
          Image(systemName: "xmark").accessibilityLabel("Capture cancelled")
        default:
          ProgressView().controlSize(.mini).accessibilityLabel("Capture pending")
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
  }
}
