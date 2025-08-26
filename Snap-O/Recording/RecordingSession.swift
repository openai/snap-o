import Foundation

final class RecordingSession: @unchecked Sendable {
  let deviceID: String
  let remotePath: String
  let process: Process
  let stderrPipe: Pipe
  let startedAt: Date

  init(deviceID: String, remotePath: String, process: Process, stderrPipe: Pipe, startedAt: Date) {
    self.deviceID = deviceID
    self.remotePath = remotePath
    self.process = process
    self.stderrPipe = stderrPipe
    self.startedAt = startedAt
  }
}
