import CoreGraphics
import Foundation
import SnapODeviceClient

/// Owns one persistent virtual touchscreen for one Android device.
actor UInputLivePreviewPointerBackend: LivePreviewPointerBackend {
  private let adb: ADBService
  private let deviceID: String
  private let touchscreen: ADBVirtualTouchscreen
  private var displayRotation: ADBDisplayRotation
  private var isStopped = false

  static func start(
    adb: ADBService,
    deviceID: String
  ) async throws -> UInputLivePreviewPointerBackend {
    let exec = await adb.exec()
    let touchscreen = try await exec.startVirtualTouchscreen(deviceID: deviceID)
    return UInputLivePreviewPointerBackend(
      adb: adb,
      deviceID: deviceID,
      touchscreen: touchscreen
    )
  }

  private init(
    adb: ADBService,
    deviceID: String,
    touchscreen: ADBVirtualTouchscreen
  ) {
    self.adb = adb
    self.deviceID = deviceID
    self.touchscreen = touchscreen
    displayRotation = touchscreen.initialDisplayRotation
  }

  func send(_ event: LivePreviewPointerEvent) async throws {
    guard !isStopped else { throw CancellationError() }
    guard event.deviceID == deviceID, event.source == .touchscreen else {
      throw ADBError.protocolFailure("virtual touchscreen received an event for the wrong device or source")
    }

    if event.action == .down {
      let exec = await adb.exec()
      let refreshedRotation = try await exec.displayRotation(deviceID: deviceID)
      guard !isStopped else { throw CancellationError() }
      displayRotation = refreshedRotation
    }

    try touchscreen.send(
      action: event.virtualTouchAction,
      x: event.location.x,
      y: event.location.y,
      displayWidth: event.displaySize.width,
      displayHeight: event.displaySize.height,
      rotation: displayRotation
    )
  }

  func stop() {
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
