import AppKit
import SwiftUI

struct CaptureWindow: View {
  @StateObject private var controller = CaptureWindowController()

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let transition = transition(for: controller.transitionDirection)

      if controller.isDeviceListInitialized || controller.currentCapture != nil {
        CaptureMediaView(controller: controller)
          .id(controller.currentCaptureViewID)
          .transition(transition)
      } else {
        WaitingForDeviceView(isDeviceListInitialized: controller.isDeviceListInitialized)
          .transition(transition)
      }
    }
    .task { await controller.start() }
    .onDisappear { controller.tearDown() }
    .focusedSceneObject(controller)
    .navigationTitle(controller.currentCapture?.device.displayTitle ?? "Snap-O")
    .toolbar {
      CaptureToolbar(controller: controller)
    }
    .overlay(alignment: .top) {
      if controller.mediaList.count > 1 {
        CapturePreviewStrip(controller: controller)
          .opacity(controller.shouldShowPreviewHint ? 1 : 0)
          .offset(y: controller.shouldShowPreviewHint ? 0 : -20)
          .padding(.top, 12)
          .allowsHitTesting(controller.shouldShowPreviewHint)
          .onHover { controller.setPreviewHintHovering($0) }
      }
    }
    .background(
      TitlebarHoverWatcher(controller: controller)
        .frame(width: 0, height: 0)
    )
    .animation(.snappy(duration: 0.25), value: controller.currentCaptureViewID)
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    return switch direction {
    case .previous: xTransition(insertion: .leading, removal: .trailing)
    case .next: xTransition(insertion: .trailing, removal: .leading)
    case .neutral: .opacity
    }
  }

  private func xTransition(insertion: Edge, removal: Edge) -> AnyTransition {
    return .asymmetric(
      insertion: .move(edge: insertion).combined(with: .opacity),
      removal: .move(edge: removal).combined(with: .opacity)
    )
  }
}

// MARK: - Preview Strip

private struct CapturePreviewStrip: View {
  @ObservedObject var controller: CaptureWindowController

  var body: some View {
      HStack(spacing: 16) {
        ForEach(controller.mediaList) { capture in
          Button {
            controller.selectMedia(id: capture.id, direction: .neutral)
          } label: {
            CapturePreviewThumbnail(
              capture: capture,
              isSelected: capture.id == controller.selectedMediaID
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
      .padding(.horizontal, 24)
  }
}

private struct CapturePreviewThumbnail: View {
  let capture: CaptureMedia
  let isSelected: Bool

  private let height: CGFloat = 72

  var body: some View {
    ZStack {
      thumbnail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6))
        .clipped()

      overlayContent
    }
    .frame(width: clampedWidth, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
    )
  }

  private var thumbnail: some View {
    switch capture.media {
    case .image(let url, _):
      if let image = NSImage(contentsOf: url) {
        return AnyView(
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        )
      } else {
        return AnyView(Color.gray)
      }
    case .video:
      return AnyView(Color.gray.opacity(0.8))
    case .livePreview:
      return AnyView(Color.black)
    }
  }

  private var overlayContent: some View {
    switch capture.media {
    case .video:
      return AnyView(
        Image(systemName: "play.fill")
          .foregroundColor(.white)
          .font(.system(size: 20, weight: .semibold))
          .shadow(radius: 4)
      )
    default:
      return AnyView(EmptyView())
    }
  }

  private var clampedWidth: CGFloat {
    let aspect = max(capture.media.aspectRatio, 0.1)
    let rawWidth = height * aspect
    return min(max(rawWidth, 56), 140)
  }
}

// MARK: - Titlebar Hover Tracking

private struct TitlebarHoverWatcher: NSViewRepresentable {
  @ObservedObject var controller: CaptureWindowController

  func makeNSView(context: Context) -> TitlebarHoverTrackingView {
    let view = TitlebarHoverTrackingView()
    view.controller = controller
    return view
  }

  func updateNSView(_ nsView: TitlebarHoverTrackingView, context: Context) {
    nsView.controller = controller
    nsView.updateTrackingIfNeeded()
  }

  static func dismantleNSView(_ nsView: TitlebarHoverTrackingView, coordinator: ()) {
    nsView.removeTrackingArea()
  }
}

private final class TitlebarHoverTrackingView: NSView {
  weak var controller: CaptureWindowController?
  private weak var trackedTitlebarView: NSView?
  private var trackingArea: NSTrackingArea?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTrackingIfNeeded()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    removeTrackingArea()
    super.viewWillMove(toWindow: newWindow)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    updateTrackingIfNeeded()
  }

  func updateTrackingIfNeeded() {
    guard let window else { return }

    let titlebarView = window.standardWindowButton(.closeButton)?.superview
    guard let titlebarView else {
      removeTrackingArea()
      return
    }

    if titlebarView !== trackedTitlebarView {
      removeTrackingArea()
      trackedTitlebarView = titlebarView
      let area = NSTrackingArea(
        rect: titlebarView.bounds,
        options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      titlebarView.addTrackingArea(area)
      trackingArea = area
    }
  }

  override func mouseEntered(with event: NSEvent) {
    controller?.handleTitlebarHover(true)
  }

  override func mouseExited(with event: NSEvent) {
    controller?.handleTitlebarHover(false)
  }

  func removeTrackingArea() {
    if let area = trackingArea, let view = trackedTitlebarView {
      view.removeTrackingArea(area)
    }
    trackingArea = nil
    trackedTitlebarView = nil
  }
}
