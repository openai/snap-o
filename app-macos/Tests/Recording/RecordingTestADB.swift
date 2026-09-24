import Foundation

final class RecordingSession: @unchecked Sendable {
  let deviceID: String
  private let lock = NSLock()
  private var result: Result<Void, Error>?
  private var waiters: [CheckedContinuation<Void, Error>] = []

  init(deviceID: String) {
    self.deviceID = deviceID
  }

  func waitUntilStopped() async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock {
        if let result { continuation.resume(with: result) }
        else { waiters.append(continuation) }
      }
    }
  }

  func waitUntilStopped(timeout _: Duration) async throws {
    try await waitUntilStopped()
  }

  func end(error: Error? = nil) {
    lock.withLock {
      guard result == nil else { return }
      let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
      result = outcome
      for waiter in waiters {
        waiter.resume(with: outcome)
      }
      waiters.removeAll()
    }
  }

  func close() {
    end()
  }
}

actor ADBService {
  private let video: URL
  private var sessions: [String: RecordingSession] = [:]
  private var unavailable: Set<String> = []
  private var failedStops: Set<String> = []
  private(set) var stops: [String] = []
  private(set) var removedRecordings: [String] = []
  private(set) var touchSettings: [String: Bool] = [:]

  init(video: URL) {
    self.video = video
  }

  func exec() -> ADBService {
    self
  }

  func displayDensity(deviceID _: String) throws -> Int {
    160
  }

  func withTimeout(_: Duration?) -> ADBService {
    self
  }

  func getShowTouches(deviceID: String) throws -> Bool {
    touchSettings[deviceID] ?? false
  }

  func setShowTouches(deviceID: String, enabled: Bool) throws {
    touchSettings[deviceID] = enabled
  }

  func startScreenrecord(deviceID: String, bugReport _: Bool) throws -> RecordingSession {
    let session = RecordingSession(deviceID: deviceID)
    sessions[deviceID] = session
    return session
  }

  func endUnexpectedly(_ deviceID: String) {
    sessions[deviceID]?.end(error: ADBError.protocolFailure("Recording stream failed"))
  }

  func failCollection(_ deviceID: String) {
    unavailable.insert(deviceID)
  }

  func failStop(_ deviceID: String) {
    failedStops.insert(deviceID)
  }

  func signalScreenrecordStop(session: RecordingSession) throws {
    stops.append(session.deviceID)
    if failedStops.contains(session.deviceID) {
      throw ADBError.requestTimedOut("Recording stop timed out")
    }
    session.end()
  }

  func downloadScreenrecord(session: RecordingSession, savingTo url: URL) throws {
    guard !unavailable.contains(session.deviceID) else {
      throw ADBError.protocolFailure("Recording file unavailable")
    }
    try FileManager.default.copyItem(at: video, to: url)
  }

  func removeScreenrecord(session: RecordingSession) throws {
    removedRecordings.append(session.deviceID)
  }
}
