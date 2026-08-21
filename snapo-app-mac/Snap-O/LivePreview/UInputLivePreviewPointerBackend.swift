import CoreGraphics
import Foundation
import SnapODeviceClient

/// Owns one persistent virtual touchscreen for one Android device.
actor UInputLivePreviewPointerBackend: LivePreviewPointerBackend {
  nonisolated var minimumMoveInterval: Duration {
    touchscreen.supportsSynchronization ? .nanoseconds(8_333_334) : .nanoseconds(16_666_667)
  }

  private let adb: ADBService
  private let deviceID: String
  private let touchscreen: ADBVirtualTouchscreen
  private var displayViewport: ADBDisplayViewport?
  private var viewportUpdatedAt = ContinuousClock.now
  private var viewportRefresh: Task<ADBDisplayViewport, Error>?
  private var idleRefresh: Task<Void, Never>?
  private var isPointerDown = false
  private var isStopped = false

  static func start(
    adb: ADBService,
    deviceID: String
  ) async throws -> UInputLivePreviewPointerBackend {
    let exec = await adb.exec()
    let touchscreen = try await exec.startVirtualTouchscreen(deviceID: deviceID)
    let backend = UInputLivePreviewPointerBackend(
      adb: adb,
      deviceID: deviceID,
      touchscreen: touchscreen
    )
    await backend.startIdleRefresh()
    return backend
  }

  private init(
    adb: ADBService,
    deviceID: String,
    touchscreen: ADBVirtualTouchscreen
  ) {
    self.adb = adb
    self.deviceID = deviceID
    self.touchscreen = touchscreen
    displayViewport = touchscreen.initialDisplayViewport
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    guard !isStopped else { throw CancellationError() }
    guard event.deviceID == deviceID, event.source == .touchscreen else {
      throw ADBError.protocolFailure("virtual touchscreen received an event for the wrong device or source")
    }

    if event.action == .down {
      isPointerDown = true
      let sizeChanged = displayViewport?.width != Int(event.displaySize.width.rounded()) ||
        displayViewport?.height != Int(event.displaySize.height.rounded())
      if viewportRefresh != nil || sizeChanged || viewportUpdatedAt.duration(to: .now) >= .seconds(1) {
        displayViewport = try await refreshViewport()
      }
    }
    guard !isStopped, let displayViewport else { throw CancellationError() }

    try touchscreen.send(
      action: event.virtualTouchAction,
      x: event.location.x,
      y: event.location.y,
      displayWidth: event.displaySize.width,
      displayHeight: event.displaySize.height,
      rotation: displayViewport.rotation
    )
    if event.action == .up || event.action == .cancel {
      isPointerDown = false
    }
  }

  private func startIdleRefresh() {
    idleRefresh = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
        guard let self else { return }
        await refreshIfIdle()
      }
    }
  }

  private func refreshIfIdle() async {
    guard !isStopped, !isPointerDown else { return }
    do {
      _ = try await refreshViewport()
    } catch is CancellationError {
      // Stopping the preview cancels its refresh request.
    } catch {
      SnapOLog.ui.debug("Unable to refresh drag rotation: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func refreshViewport() async throws -> ADBDisplayViewport {
    if let viewportRefresh { return try await viewportRefresh.value }
    let task = Task { [adb, deviceID] in
      let exec = await adb.exec()
      return try await exec.displayViewport(deviceID: deviceID)
    }
    viewportRefresh = task
    defer { viewportRefresh = nil }
    do {
      let viewport = try await task.value
      guard !isStopped else { throw CancellationError() }
      displayViewport = viewport
      viewportUpdatedAt = .now
      return viewport
    } catch {
      displayViewport = nil
      throw error
    }
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    idleRefresh?.cancel()
    idleRefresh = nil
    viewportRefresh?.cancel()
    touchscreen.close()
  }
}

private extension LivePreviewPointerEvent {
  var virtualTouchAction: ADBVirtualTouchAction {
    switch action {
    case .down: .down
    case .move: .move
    case .up: .up
    case .cancel: .cancel
    }
  }
}
