@preconcurrency import AVFoundation
import Dependencies
import Foundation

/// Keeps the device helper connected while capture is paused.
@MainActor
final class DeviceVideoConnection: LivePreviewFrameSource {
  private(set) var hasIndependentFrames = false
  private let target: DeviceTarget
  private let clock: AnyClock<Duration>
  private(set) var hasStopped = false
  private var connection: (any ADBConnection)?
  private var isReady = false
  private var captureRequested = false
  private var waitingForPause = false
  private var receivedKeyFrame = false
  private var keyFrameRequested = false
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
    captureRequested = false
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
    // The encoder supplies the first keyframe itself. One later request serves all joiners.
    guard receivedKeyFrame, !keyFrameRequested, captureRequested else { return }
    keyFrameRequested = true
    send(1)
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    guard !hasStopped, !captureRequested else { return }
    self.deliver = deliver
    captureRequested = true
    armTimeout("Device video did not start")
    prepare()
    if isReady, !waitingForPause { send(5) }
  }

  func pause() {
    guard !hasStopped, captureRequested else { return }
    captureRequested = false
    deliver = nil
    receivedKeyFrame = false
    keyFrameRequested = false
    hasIndependentFrames = false
    timeout?.cancel()
    if isReady, !waitingForPause {
      waitingForPause = true
      armTimeout("Device video did not pause")
      send(4)
    }
  }

  private func armTimeout(_ message: String) {
    timeout?.cancel()
    let deadline = clock.now.advanced(by: .seconds(8))
    timeout = Task { [weak self, clock] in
      guard !Task.isCancelled else { return }
      do { try await clock.sleep(until: deadline) } catch { return }
      self?.receive(.stopped(ADBError.requestTimedOut(message)))
    }
  }

  private func send(_ command: UInt8) {
    guard !hasStopped, let connection else { return }
    commands.async {
      do {
        try connection.writeFully(ADBShellV2Stream.standardInput(Data([command])))
      } catch { connection.close() }
    }
  }

  func prepare() {
    guard task == nil, !hasStopped else { return }
    let target = target
    let commands = commands
    task = Task.detached(priority: .userInitiated) { [weak self] in
      guard !Task.isCancelled else { return }
      var socket: (any ADBConnection)?
      do {
        let helper = try DeviceHelper(DeviceHelper.bundledBytes())
        let session = try await helper.connect(.video, serial: target.serial, adb: ADBClient().bound(to: target))
        let connection = session.connection
        socket = connection
        let acknowledgeRGBAFrame = {
          try commands.sync {
            try connection.writeFully(ADBShellV2Stream.standardInput(Data([3])))
          }
        }
        guard await self?.install(connection) == true else { connection.close()
          return
        }
        try Task.checkCancellation()
        var stream = session.stream
        try DeviceVideoPacket.validateHeader(session.header)
        await self?.markReady()
        var builder = DeviceVideoSampleBuilder()
        let rgbaBuilder = EmulatorPreviewFrameBuilder()
        var displaySize: (width: Int, height: Int)?
        var rgbaSize: (width: Int, height: Int)?
        while !Task.isCancelled {
          let packet = try DeviceVideoPacket.read { try stream.readExactly($0, read: connection.readChunk) }
          switch packet {
          case .failure(let error):
            throw error
          case .paused:
            builder.reset()
            displaySize = nil
            rgbaSize = nil
            await self?.didPause()
          case .display(let width, let height, let density, _):
            builder.reset()
            displaySize = (width, height)
            rgbaSize = nil
            await self?.beginDisplay(density: CGFloat(density) / 160)
          case .rgba(let width, let height, let timestamp, let pixels):
            guard displaySize?.width == width, displaySize?.height == height else {
              throw ADBError.protocolFailure("RGBA frame does not match the device display")
            }
            guard let sample = try rgbaBuilder.makeSample(
              rgba: pixels, width: width, height: height, timestamp: UInt64(timestamp)
            ) else {
              try acknowledgeRGBAFrame()
              continue
            }
            await self?.useIndependentFrames()
            if rgbaSize?.width != width || rgbaSize?.height != height,
               let format = CMSampleBufferGetFormatDescription(sample) {
              await self?.receive(.format(format))
              rgbaSize = (width, height)
            }
            await self?.receive(.sample(sample, isKeyFrame: true))
            try acknowledgeRGBAFrame()
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
    isReady = true
    if captureRequested { send(5) }
  }

  private func didPause() {
    guard waitingForPause, !hasStopped else { return }
    waitingForPause = false
    if captureRequested {
      send(5)
    } else { timeout?.cancel() }
  }

  private func beginDisplay(density: CGFloat) {
    receivedKeyFrame = false
    keyFrameRequested = false
    receive(.density(density))
  }

  private func useIndependentFrames() {
    if captureRequested, !waitingForPause { hasIndependentFrames = true }
  }

  private func install(_ connection: any ADBConnection) -> Bool {
    guard !hasStopped else { return false }
    self.connection = connection
    return true
  }

  private func receive(_ event: LivePreviewFrameEvent) {
    guard !hasStopped else { return }
    let receiver = deliver
    if case .stopped = event {
      stop()
    } else {
      guard captureRequested, !waitingForPause else { return }
      if case .sample(_, let keyFrame) = event {
        timeout?.cancel()
        if keyFrame {
          receivedKeyFrame = true
          keyFrameRequested = false
        }
      }
    }
    receiver?(event)
  }
}
