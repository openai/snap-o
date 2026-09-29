import SwiftUI

struct CaptureReviewView: View {
  @Bindable var controller: CaptureWindowController
  @Environment(CaptureHistory.self)
  private var history
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isNaming = false
  @State private var isFinishing = false
  @State private var errorMessage: String?

  var body: some View {
    GeometryReader { geometry in
      if let capture = controller.currentCapture {
        let frame = CaptureReviewLayout.mediaFrame(in: geometry.size, aspectRatio: capture.media.aspectRatio)
        ZStack(alignment: .topLeading) {
          Color(white: 0.12)
          reviewToolbar
            .frame(height: CaptureReviewLayout.toolbarHeight)
            .padding(.horizontal, CaptureReviewLayout.edgeSpacing)
            .padding(.vertical, CaptureReviewLayout.toolbarSpacing)
          CaptureMediaView(fileStore: controller.fileStore, livePreviewHost: controller, capture: capture)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: frame)
            .zIndex(1)
        }
      }
    }
    .environment(\.colorScheme, .dark)
    .background(CaptureSheetAnchor(isPresented: isNaming))
    .sheet(isPresented: $isNaming) {
      CaptureSaveSheet { name in
        controller.isSavingReview = true
        defer { controller.isSavingReview = false }
        let captures = controller.mediaList
        try await history.repository.saveReviewedCaptures(captures, name: name, selectedID: controller.selectedMediaID)
        // The durable copy is complete; temporary-file cleanup must not cause a duplicate save.
        try? controller.fileStore.discardPreviews(captures)
        isNaming = false
        controller.isSavingReview = false
        await controller.finishCaptureReview()
      }
    }
    .alert("Could Not Discard Captures", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var reviewToolbar: some View {
    HStack(spacing: 12) {
      Button {
        discard()
      } label: {
        Image(systemName: "xmark")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.white)
      .glassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: Circle())
      .help("Discard Captures")
      .accessibilityLabel("Discard captures")

      if controller.mediaList.count > 1 {
        CaptureReviewThumbnails(
          captures: controller.mediaList,
          selectedID: controller.selectedMediaID
        ) { controller.selectMedia(id: $0) }
      } else {
        Spacer(minLength: 0)
      }

      Button { isNaming = true } label: {
        Image(systemName: "checkmark")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.white)
      .glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
      .help("Save Captures to History")
      .accessibilityLabel("Save captures to history")
    }
    .disabled(isFinishing || controller.isProcessing || controller.isSavingReview)
  }

  private func discard() {
    guard !isFinishing else { return }
    do {
      try controller.fileStore.discardPreviews(controller.mediaList)
      isFinishing = true
      Task { await controller.finishCaptureReview() }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct CaptureReviewThumbnails: View {
  let captures: [CaptureMedia]
  let selectedID: UUID?
  let select: (UUID) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(captures) { capture in
            Button { select(capture.id) } label: {
              CaptureReviewThumbnail(capture: capture)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                  RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(capture.id == selectedID ? Color.accentColor : .clear, lineWidth: 2)
                }
            }
            .buttonStyle(.plain)
            .help(capture.device.displayTitle)
            .accessibilityLabel(capture.device.displayTitle)
            .accessibilityAddTraits(capture.id == selectedID ? .isSelected : [])
            .id(capture.id)
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

private struct CaptureReviewThumbnail: View {
  let capture: CaptureMedia
  @State private var imageLoader = ImageLoader()

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if case .image(let url, _) = capture.media, let image = imageLoader.image(url: url) {
          Image(nsImage: image).resizable().scaledToFill()
        } else if case .video(let url, _) = capture.media {
          VideoPreviewThumbnail(url: url)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
      .overlay(alignment: .bottomTrailing) {
        if capture.media.isVideo {
          Image(systemName: "video.fill")
            .font(.system(size: 8))
            .foregroundStyle(.white)
            .shadow(radius: 1)
            .padding(2)
        }
      }
    }
  }
}

private struct CaptureSaveSheet: View {
  let save: @MainActor (String) async throws -> Void
  @Environment(\.dismiss)
  private var dismiss
  @State private var name = ""
  @State private var isSaving = false
  @State private var errorMessage: String?
  @FocusState private var isNameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Save to Capture History").font(.headline)
      TextField("Name (optional)", text: $name)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Capture name")
        .focused($isNameFocused)
        .onSubmit(submit)
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if isSaving { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save", action: submit).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 320)
    .disabled(isSaving)
    .interactiveDismissDisabled(isSaving)
    .onAppear { isNameFocused = true }
  }

  private func submit() {
    guard !isSaving else { return }
    isSaving = true
    errorMessage = nil
    Task {
      do {
        try await save(name)
      } catch {
        errorMessage = error.localizedDescription
        isSaving = false
      }
    }
  }
}
