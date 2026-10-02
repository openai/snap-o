import Foundation
import Observation

enum DeviceCaptureActivity: String {
  case screenshot
  case recording
  case bugReportRecording = "bug-report recording"
  case livePreview = "live preview"
}

enum CaptureCoordinationError: LocalizedError, Equatable {
  case noDevices
  case captureBusy(DeviceCaptureActivity)
  case deviceBusy(deviceID: String, activity: DeviceCaptureActivity)
  case closed

  var errorDescription: String? {
    switch self {
    case .noDevices:
      "No devices are available for capture."
    case .captureBusy(let activity):
      "Another \(activity.rawValue) is in progress. Wait for it to finish before starting a capture."
    case .deviceBusy(let deviceID, let activity):
      "\(deviceID) is already being used for \(activity.rawValue) in another window."
    case .closed:
      "Capture is unavailable while Snap-O is shutting down."
    }
  }
}

struct DeviceCaptureLease: Hashable {
  fileprivate let id: UUID
}

/// Allows one capture across all windows while keeping compatible previews running.
@Observable
@MainActor
final class CaptureCoordinator {
  private var leases: [UUID: (devices: Set<String>, activity: DeviceCaptureActivity)] = [:]
  @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var isClosed = false

  nonisolated init() {}

  var captureActivity: DeviceCaptureActivity? {
    leases.values.first { $0.activity != .livePreview }?.activity
  }

  var isCapturing: Bool {
    captureActivity != nil
  }

  func acquire(
    deviceIDs: [String],
    for activity: DeviceCaptureActivity
  ) throws -> DeviceCaptureLease {
    guard !isClosed else { throw CaptureCoordinationError.closed }

    let deviceIDs = Set(deviceIDs)
    guard !deviceIDs.isEmpty else { throw CaptureCoordinationError.noDevices }

    if activity != .livePreview, let captureActivity {
      throw CaptureCoordinationError.captureBusy(captureActivity)
    }

    for deviceID in deviceIDs.sorted() {
      if let occupant = leases.values.first(where: { $0.devices.contains(deviceID) && !Self.canShare(activity, $0.activity) }) {
        throw CaptureCoordinationError.deviceBusy(deviceID: deviceID, activity: occupant.activity)
      }
    }

    let lease = DeviceCaptureLease(id: UUID())
    leases[lease.id] = (deviceIDs, activity)
    return lease
  }

  private static func canShare(_ first: DeviceCaptureActivity, _ second: DeviceCaptureActivity) -> Bool {
    first != .bugReportRecording && second != .bugReportRecording
  }

  func release(_ lease: DeviceCaptureLease) {
    guard leases.removeValue(forKey: lease.id) != nil else { return }
    resumeIdleWaitersIfNeeded()
  }

  func beginShutdown() {
    isClosed = true
  }

  func waitUntilIdle() async {
    guard !leases.isEmpty else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  private func resumeIdleWaitersIfNeeded() {
    guard leases.isEmpty else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
