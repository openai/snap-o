import Foundation
import Observation

enum DeviceCaptureActivity: String {
  case screenshot
  case recording
  case bugReportRecording = "bug-report recording"
  case livePreview = "live preview"
}

enum CaptureCoordinationError: LocalizedError, Equatable {
  case deviceBusy(deviceID: String, activity: DeviceCaptureActivity)
  case closed

  var errorDescription: String? {
    switch self {
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

/// Protects conflicting device work without a global capture slot.
@Observable
@MainActor
final class CaptureCoordinator {
  private struct Reservation {
    let target: DeviceTarget
    let activity: DeviceCaptureActivity
  }

  private var leases: [UUID: Reservation] = [:]
  @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var isClosed = false

  nonisolated init() {}

  func acquire(target: DeviceTarget, for activity: DeviceCaptureActivity) throws -> DeviceCaptureLease {
    guard !isClosed else { throw CaptureCoordinationError.closed }
    _ = try target.requireTransport(for: target.serial)
    for held in leases.values where held.target == target {
      let exclusive = activity == .bugReportRecording || held.activity == .bugReportRecording
      let emulatorRecording = EmulatorGRPCEndpoint.isEmulator(target.serial)
        && activity == .recording && held.activity == .recording
      if exclusive || emulatorRecording {
        throw CaptureCoordinationError.deviceBusy(deviceID: target.serial, activity: held.activity)
      }
    }
    let lease = DeviceCaptureLease(id: UUID())
    leases[lease.id] = Reservation(target: target, activity: activity)
    return lease
  }

  func release(_ lease: DeviceCaptureLease) {
    guard leases.removeValue(forKey: lease.id) != nil, leases.isEmpty else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func beginShutdown() { isClosed = true }

  func waitUntilIdle() async {
    guard !leases.isEmpty else { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }
}
