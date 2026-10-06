@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Owns one physical device encoder and its socket.
@MainActor
final class DeviceVideoConnection: LivePreviewFrameSource {
  let hasIndependentFrames = false
  private let target: DeviceTarget
  private let clock: AnyClock<Duration>
  private var hasStopped = false
  private var connection: (any ADBConnection)?
  private var isReady = false
  private var task: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var deliver: (@MainActor @Sendable (LivePreviewFrameEvent) -> Void)?
  private let commands = DispatchQueue(label: "snapo.video.commands")

  init(target: DeviceTarget) {
    @Dependency(\.continuousClock)
    var clock
    self.clock = AnyClock(clock)
    self.target = target
  }

  func stop() {
    hasStopped = true
    task?.cancel()
    timeout?.cancel()
    connection?.close()
    connection = nil
    deliver = nil
  }

  func waitUntilStopped() async {
    await task?.value
    await timeout?.value
    await withCheckedContinuation { continuation in
      commands.async { continuation.resume() }
    }
  }

  func requestKeyFrame() {
    guard isReady, !hasStopped, let connection else { return }
    commands.async { try? connection.writeFully(Data([1])) }
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    guard task == nil, !hasStopped else { return }
    self.deliver = deliver
    let target = target
    let deviceID = target.serial
    let clock = clock
    timeout = Task { [weak self] in
      guard !Task.isCancelled else { return }
      do { try await clock.sleep(for: .seconds(8)) } catch { return }
      self?.receive(.stopped(ADBError.requestTimedOut("Device video did not start")))
      self?.stop()
    }
    task = Task.detached(priority: .userInitiated) { [weak self] in
      guard !Task.isCancelled else { return }
      var socket: (any ADBConnection)?
      do {
        guard let url = Bundle.main.url(forResource: "snapo-device-helper", withExtension: "jar") else {
          throw ADBError.protocolFailure("Missing device video helper")
        }
        let helper = try Data(contentsOf: url)
        guard !helper.isEmpty, helper.count <= 128 * 1024 else { throw ADBError.protocolFailure("Invalid device helper") }
        let command = """
        directory=$(mktemp -d /data/local/tmp/snapo-video.XXXXXX) || exit 1
        trap 'rm -f "$directory/helper.jar"; rmdir "$directory" 2>/dev/null' EXIT
        (umask 077; printf '%s' '\(helper.base64EncodedString())' | base64 -d > "$directory/helper.jar") &&
          chmod 444 "$directory/helper.jar" || exit 1
        CLASSPATH="$directory/helper.jar" app_process / com.openai.snapo.video.Main "$directory" 2>/dev/null
        """
        let connection = try await ADBClient().bound(to: target).makeConnection()
        socket = connection
        guard await self?.install(connection) == true else { connection.close()
          return
        }
        try Task.checkCancellation()
        try connection.withRequestTimeout(.seconds(8)) {
          try connection.sendTransport(to: deviceID)
          _ = try connection.sendHostCommand("exec:" + command, expectsResponse: false)
          try DeviceVideoPacket.validateHeader(Self.readExactly(4, from: connection))
        }
        await self?.markReady()
        var builder = DeviceVideoSampleBuilder()
        while !Task.isCancelled {
          let packet = try DeviceVideoPacket.read { try Self.readExactly($0, from: connection) }
          switch packet {
          case .display(_, _, let density, _):
            builder.reset()
            await self?.receive(.density(CGFloat(density) / 160))
          case .frame(let flags, let timestamp, let data):
            let oldFormat = builder.format
            let sample = try builder.sample(data: data, timestamp: timestamp, flags: flags)
            if oldFormat == nil, let format = builder.format { await self?.receive(.format(format)) }
            if let sample { await self?.receive(.sample(sample, isKeyFrame: flags & 1 != 0)) }
          }
        }
      } catch {
        await self?.receive(.stopped(Task.isCancelled ? nil : error))
      }
      socket?.close()
    }
  }

  private func markReady() {
    guard !hasStopped else { return }
    // New encoders start with a keyframe. Later subscribers request a fresh one.
    isReady = true
  }

  private func install(_ connection: any ADBConnection) -> Bool {
    guard !hasStopped else { return false }
    self.connection = connection
    return true
  }

  private func receive(_ event: LivePreviewFrameEvent) {
    guard !hasStopped else { return }
    if case .sample = event { timeout?.cancel() }
    let receiver = deliver
    if case .stopped = event { stop() }
    receiver?(event)
  }

  private nonisolated static func readExactly(_ count: Int, from connection: any ADBConnection) throws -> Data {
    var bytes = Data()
    while bytes.count < count {
      guard let chunk = try connection.readChunk(maxLength: count - bytes.count), !chunk.isEmpty else {
        throw ADBError.protocolFailure("Device video disconnected")
      }
      bytes.append(chunk)
    }
    return bytes
  }
}
