import Foundation

final class ScreenStreamSession: @unchecked Sendable {
  let deviceID: String
  let process: Process
  let stdoutPipe: Pipe
  let stderrPipe: Pipe
  let startedAt: Date

  init(deviceID: String, process: Process, stdoutPipe: Pipe, stderrPipe: Pipe, startedAt: Date) {
    self.deviceID = deviceID
    self.process = process
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
    self.startedAt = startedAt
  }
}
