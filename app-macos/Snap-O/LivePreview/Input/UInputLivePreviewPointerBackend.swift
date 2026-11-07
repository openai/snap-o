import CoreGraphics
import Foundation

protocol LivePreviewTouchscreen: Sendable {
  var supportsSynchronization: Bool { get }
  var initialDisplayRotation: ADBDisplayRotation { get }
  func send(_ event: LivePreviewPointerEvent, rotation: ADBDisplayRotation) throws
  func close()
}

extension ADBVirtualTouchscreen: LivePreviewTouchscreen {
  func send(_ event: LivePreviewPointerEvent, rotation: ADBDisplayRotation) throws {
    try send(
      action: event.virtualTouchAction, locations: event.locations,
      displayWidth: event.displaySize.width, displayHeight: event.displaySize.height, rotation: rotation
    )
  }
}

/// Owns one persistent virtual touchscreen for one Android device.
actor UInputLivePreviewPointerBackend: LivePreviewPointerBackend {
  nonisolated var minimumMoveInterval: Duration {
    touchscreen.supportsSynchronization ? .nanoseconds(8_333_334) : .nanoseconds(16_666_667)
  }

  private let readRotation: @Sendable () async throws -> ADBDisplayRotation
  private let target: DeviceTarget
  private let touchscreen: any LivePreviewTouchscreen
  private var displayRotation: ADBDisplayRotation
  private var isStopped = false

  static func start(
    adb: ADBService,
    target: DeviceTarget
  ) async throws -> UInputLivePreviewPointerBackend {
    let exec = await adb.exec().bound(to: target)
    let touchscreen = try await exec.startVirtualTouchscreen(deviceID: target.serial)
    return UInputLivePreviewPointerBackend(
      target: target,
      touchscreen: touchscreen
    ) {
      if target.isLocalEmulator {
        return try await EmulatorRotationClient.rotation(target: target)
      }
      let exec = await adb.exec().bound(to: target)
      return try await exec.displayRotation(deviceID: target.serial)
    }
  }

  init(
    target: DeviceTarget,
    touchscreen: any LivePreviewTouchscreen,
    readRotation: @escaping @Sendable () async throws -> ADBDisplayRotation
  ) {
    self.readRotation = readRotation
    self.target = target
    self.touchscreen = touchscreen
    displayRotation = touchscreen.initialDisplayRotation
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    guard !isStopped, target.isValid else { throw CancellationError() }
    guard event.target == target, event.source == .touchscreen else {
      throw ADBError.protocolFailure("virtual touchscreen received an event for the wrong device or source")
    }

    if event.action == .down {
      let refreshedRotation = try await readRotation()
      guard !isStopped, target.isValid else { throw CancellationError() }
      displayRotation = refreshedRotation
    }

    try touchscreen.send(event, rotation: displayRotation)
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
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
