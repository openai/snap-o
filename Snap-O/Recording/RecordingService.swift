import Foundation
import Observation

actor RecordingService {
  private let adb: ADBClient
  private let store: FileStore

  private struct ActiveRecording {
    let token: UUID
    let session: RecordingSession
  }

  private var recordings: [String: ActiveRecording] = [:]

  init(adb: ADBClient, store: FileStore) {
    self.adb = adb
    self.store = store
  }

  func start(deviceID: String) async throws -> RecordingHandle {
    if recordings[deviceID] != nil {
      throw ADBError.alreadyRecording
    }
    let size = try? await adb.getCurrentDisplaySize(deviceID: deviceID)
    let session = try await adb.startScreenrecord(deviceID: deviceID, size: size)
    let token = UUID()
    recordings[deviceID] = ActiveRecording(token: token, session: session)
    notifyRecordingDevices()
    return RecordingHandle(token: token, deviceID: deviceID)
  }

  func stop(handle: RecordingHandle, savingTo url: URL) async throws {
    guard let active = recordings[handle.deviceID], active.token == handle.token else {
      throw ADBError.notRecording
    }
    try await adb.stopScreenrecord(session: active.session, savingTo: url)
    recordings.removeValue(forKey: handle.deviceID)
    notifyRecordingDevices()
  }

  func isRecording(deviceID: String) -> Bool {
    recordings[deviceID] != nil
  }

  func recordingDevicesStream() -> AsyncStream<Set<String>> {
    let id = UUID()
    return AsyncStream { continuation in
      recordingContinuations[id] = continuation
      continuation.yield(currentRecordingDevices())
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(id) }
      }
    }
  }

  func currentRecordingDevices() -> Set<String> {
    Set(recordings.keys)
  }

  private func notifyRecordingDevices() {
    let set = currentRecordingDevices()
    for continuation in recordingContinuations.values {
      continuation.yield(set)
    }
  }

  private func removeContinuation(_ id: UUID) {
    recordingContinuations.removeValue(forKey: id)
  }

  private var recordingContinuations: [UUID: AsyncStream<Set<String>>.Continuation] = [:]
}
