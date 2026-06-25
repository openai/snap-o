import Foundation

enum DeviceCaptureActivity: String {
  case recording
  case livePreview = "live preview"
}

enum CaptureCoordinationError: LocalizedError, Equatable {
  case noDevices
  case deviceBusy(deviceID: String, activity: DeviceCaptureActivity)
  case closed

  var errorDescription: String? {
    switch self {
    case .noDevices:
      "No devices are available for capture."
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

/// Owns app-wide policy shared by mutually exclusive capture modes.
actor CaptureCoordinator {
  private struct Occupant {
    let leaseID: UUID
    let activity: DeviceCaptureActivity
  }

  private var occupants: [String: Occupant] = [:]
  private var deviceIDsByLeaseID: [UUID: Set<String>] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var isClosed = false

  func acquire(
    deviceIDs: [String],
    for activity: DeviceCaptureActivity
  ) throws -> DeviceCaptureLease {
    guard !isClosed else { throw CaptureCoordinationError.closed }

    let deviceIDs = Set(deviceIDs)
    guard !deviceIDs.isEmpty else { throw CaptureCoordinationError.noDevices }

    for deviceID in deviceIDs.sorted() {
      if let occupant = occupants[deviceID] {
        throw CaptureCoordinationError.deviceBusy(
          deviceID: deviceID,
          activity: occupant.activity
        )
      }
    }

    let lease = DeviceCaptureLease(id: UUID())
    for deviceID in deviceIDs {
      occupants[deviceID] = Occupant(
        leaseID: lease.id,
        activity: activity
      )
    }
    deviceIDsByLeaseID[lease.id] = deviceIDs
    return lease
  }

  func release(_ lease: DeviceCaptureLease) {
    guard let deviceIDs = deviceIDsByLeaseID.removeValue(forKey: lease.id) else { return }

    for deviceID in deviceIDs where occupants[deviceID]?.leaseID == lease.id {
      occupants.removeValue(forKey: deviceID)
    }
    resumeIdleWaitersIfNeeded()
  }

  func beginShutdown() {
    isClosed = true
  }

  func waitUntilIdle() async {
    guard !deviceIDsByLeaseID.isEmpty else { return }
    await withCheckedContinuation { continuation in
      idleWaiters.append(continuation)
    }
  }

  private func resumeIdleWaitersIfNeeded() {
    guard deviceIDsByLeaseID.isEmpty else { return }
    let waiters = idleWaiters
    idleWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
