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

/// Allows a preview and recording together, with one owner for each activity.
actor CaptureCoordinator {
  private var leases: [UUID: (devices: Set<String>, activity: DeviceCaptureActivity)] = [:]
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var isClosed = false

  func acquire(
    deviceIDs: [String],
    for activity: DeviceCaptureActivity
  ) throws -> DeviceCaptureLease {
    guard !isClosed else { throw CaptureCoordinationError.closed }

    let deviceIDs = Set(deviceIDs)
    guard !deviceIDs.isEmpty else { throw CaptureCoordinationError.noDevices }

    for deviceID in deviceIDs.sorted() where leases.values.contains(where: { $0.activity == activity && $0.devices.contains(deviceID) }) {
      throw CaptureCoordinationError.deviceBusy(deviceID: deviceID, activity: activity)
    }

    let lease = DeviceCaptureLease(id: UUID())
    leases[lease.id] = (deviceIDs, activity)
    return lease
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
