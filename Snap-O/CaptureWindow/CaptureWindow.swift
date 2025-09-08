import SwiftUI

struct CaptureWindow: View {
  @StateObject private var deviceSelectionController = CaptureDeviceSelectionController()
  private let transitionOffset: CGFloat = 60

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      let selectedID = deviceSelectionController.devices.selectedID

      let transition = transition(for: deviceSelectionController.transitionDirection)

      if let deviceID = selectedID {
        CaptureDeviceView(
          deviceID: deviceID,
          deviceSelectionController: deviceSelectionController
        )
        .id(deviceID)
        .transition(transition)
      } else {
        WaitingForDeviceView(isDeviceListInitialized: deviceSelectionController.isDeviceListInitialized)
          .transition(transition)
      }
    }
    .task { await deviceSelectionController.start() }
    .focusedSceneObject(deviceSelectionController)
    .toolbar {
      TitleDevicePickerToolbar(deviceSelection: deviceSelectionController)
    }
    .animation(.snappy(duration: 0.25), value: deviceSelectionController.devices.selectedID)
    .background(
      WindowTitleVisibilityController()
        .frame(width: 0, height: 0)
    )
  }
}

private struct CaptureDeviceView: View {
  let deviceID: String
  @ObservedObject var deviceSelectionController: CaptureDeviceSelectionController

  @StateObject private var controller: CaptureController
  private let dismissalDelayNanoseconds: UInt64 = 300_000_000
  @State private var projectedMedia: Media?
  @State private var isProjecting = false
  private var isCurrentSelection: Bool {
    deviceSelectionController.devices.selectedID == deviceID
  }

  init(deviceID: String, deviceSelectionController: CaptureDeviceSelectionController) {
    self.deviceID = deviceID
    self.deviceSelectionController = deviceSelectionController
    _controller = StateObject(
      wrappedValue: CaptureController(
        deviceID: deviceID
      )
    )
  }

  var body: some View {
    ZStack {
      if let media = controller.currentMedia {
        MediaDisplayView(media: media, controller: controller)
          .transition(
            media.isLivePreview
              ? AnyTransition.opacity
              : AnyTransition.scale(scale: 0.9).combined(with: .opacity)
          )
      } else {
        IdleOverlayView(
          controller: controller,
          hasDevices: deviceSelectionController.hasDevices,
          isDeviceListInitialized: deviceSelectionController.isDeviceListInitialized
        )
      }
    }
    .animation(.snappy(duration: 0.15), value: controller.currentMedia != nil)
    .background(
      WindowSizingController(currentMedia: controller.currentMedia ?? projectedMedia)
        .frame(width: 0, height: 0)
    )
    .onOpenURL { controller.handle(url: $0) }
    .focusedSceneObject(controller)
    .toolbar {
      CaptureToolbar(controller: controller)
    }
    .onAppear { handleMediaChange(controller.currentMedia) }
    .onChange(of: controller.currentMedia) { _, newMedia in
      handleMediaChange(newMedia)
    }
    .onDisappear {
      Task {
        try? await Task.sleep(nanoseconds: dismissalDelayNanoseconds)
        await controller.prepareForDismissal()
      }
      deviceSelectionController.updateShouldPreserveSelection(false)
      projectedMedia = nil
      isProjecting = false
    }
    .onChange(of: controller.deviceUnavailableSignal) {
      deviceSelectionController.handleDeviceUnavailable(currentDeviceID: deviceID)
    }
    .zIndex(isCurrentSelection ? 1 : 2)
  }

  private func handleMediaChange(_ media: Media?) {
    let shouldPreserveSelection = media?.isLivePreview == false
    deviceSelectionController.updateShouldPreserveSelection(shouldPreserveSelection)

    guard media == nil else {
      projectedMedia = nil
      isProjecting = false
      return
    }

    refreshProjectedMediaIfNeeded()
  }

  private func refreshProjectedMediaIfNeeded() {
    guard controller.currentMedia == nil, !isProjecting else { return }
    isProjecting = true
    Task {
      defer { DispatchQueue.main.async { isProjecting = false } }
      guard let media = await fetchProjectedMedia() else { return }
      await MainActor.run { projectedMedia = media }
    }
  }

  private func fetchProjectedMedia() async -> Media? {
    do {
      let adbService = AppServices.shared.adbService
      let exec = try await adbService.exec()
      let sizeString = try await exec.getCurrentDisplaySize(deviceID: deviceID)
      guard let size = parseDisplaySize(sizeString) else { return nil }
      let density = try? await exec.screenDensityScale(deviceID: deviceID)
      return Media.livePreview(capturedAt: Date(), size: size, densityScale: density)
    } catch {
      return nil
    }
  }

  private func parseDisplaySize(_ rawValue: String) -> CGSize? {
    let parts = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
    guard parts.count == 2,
          let width = Double(parts[0]),
          let height = Double(parts[1])
    else { return nil }
    return CGSize(width: width, height: height)
  }
}

extension CaptureWindow {
  private func transition(for direction: DeviceTransitionDirection) -> AnyTransition {
    switch direction {
    case .up:
      let move = AnyTransition.offset(y: transitionOffset).combined(with: .opacity)
      return .asymmetric(
        insertion: move,
        removal: .offset(y: -transitionOffset).combined(with: .opacity)
      )
    case .down:
      let move = AnyTransition.offset(y: -transitionOffset).combined(with: .opacity)
      return .asymmetric(
        insertion: move,
        removal: .offset(y: transitionOffset).combined(with: .opacity)
      )
    case .neutral:
      return .opacity
    }
  }
}

private struct WaitingForDeviceView: View {
  let isDeviceListInitialized: Bool

  var body: some View {
    VStack(spacing: 12) {
      Image("Aperture")
        .resizable()
        .frame(width: 64, height: 64)
        .infiniteRotate(animated: true)

      if !isDeviceListInitialized {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading devices…")
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      } else {
        Text("Waiting for device…")
          .foregroundStyle(.gray)
          .transition(.opacity)
      }
    }
  }
}
