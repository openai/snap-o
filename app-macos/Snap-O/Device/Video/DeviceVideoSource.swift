@preconcurrency import AVFoundation
import Foundation

/// Shares a physical device's encoder across preview renderers and recorders.
@MainActor
final class DeviceVideoHub {
  static let shared = DeviceVideoHub()
  private var sessions: [String: DeviceVideoStream] = [:]

  func subscribe(deviceID: String, receive: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) -> UUID {
    let stream: DeviceVideoStream
    if let existing = sessions[deviceID], !existing.hasStopped {
      stream = existing
    } else {
      stream = DeviceVideoStream(deviceID: deviceID)
      sessions[deviceID] = stream
    }
    return stream.subscribe(receive)
  }

  func unsubscribe(deviceID: String, id: UUID) {
    guard let stream = sessions[deviceID] else { return }
    stream.unsubscribe(id)
    if stream.isEmpty {
      stream.stop()
      sessions.removeValue(forKey: deviceID)
    }
  }
}

@MainActor
final class DeviceVideoSource: LivePreviewFrameSource {
  let hasIndependentFrames = false
  private let deviceID: String
  private var subscription: UUID?

  init(deviceID: String) {
    self.deviceID = deviceID
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    guard subscription == nil else { return }
    subscription = DeviceVideoHub.shared.subscribe(deviceID: deviceID, receive: deliver)
  }

  func stop() {
    guard let subscription else { return }
    self.subscription = nil
    DeviceVideoHub.shared.unsubscribe(deviceID: deviceID, id: subscription)
  }
}

@MainActor
final class DeviceVideoStream {
  private struct Subscriber {
    let receive: @MainActor @Sendable (LivePreviewFrameEvent) -> Void
    var needsKeyFrame = true
  }

  let deviceID: String
  private(set) var hasStopped = false
  private var subscribers: [UUID: Subscriber] = [:]
  private let client: ADBClient
  private var connection: ADBSocketConnection?
  private var isReady = false
  private var task: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var format: CMVideoFormatDescription?
  private var density: CGFloat?
  private let commands = DispatchQueue(label: "snapo.video.commands")
  var isEmpty: Bool {
    subscribers.isEmpty
  }

  init(deviceID: String, client: ADBClient = ADBClient()) {
    self.deviceID = deviceID
    self.client = client
  }

  func subscribe(_ receive: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) -> UUID {
    let id = UUID()
    subscribers[id] = Subscriber(receive: receive)
    if let density { receive(.density(density)) }
    if let format { receive(.format(format)) }
    if task == nil { start() }
    requestKeyFrame()
    return id
  }

  func unsubscribe(_ id: UUID) {
    subscribers.removeValue(forKey: id)
  }

  func stop() {
    task?.cancel()
    timeout?.cancel()
    connection?.close()
    connection = nil
    hasStopped = true
  }

  private func requestKeyFrame() {
    guard isReady, !hasStopped, let connection else { return }
    commands.async { try? connection.writeFully(Data([1])) }
  }

  private func start() {
    let deviceID = deviceID
    let client = client
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      self?.receive(.stopped(ADBError.requestTimedOut("Device video did not start")))
      self?.stop()
    }
    task = Task.detached(priority: .userInitiated) { [weak self] in
      var socket: ADBSocketConnection?
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
        let connection = try await client.makeConnection()
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
    isReady = true
    requestKeyFrame()
  }

  private func install(_ connection: ADBSocketConnection) -> Bool {
    guard !hasStopped else { return false }
    self.connection = connection
    return true
  }

  private func receive(_ event: LivePreviewFrameEvent) {
    guard !hasStopped else { return }
    switch event {
    case .density(let density):
      self.density = density
    case .format(let description):
      format = description
      for id in subscribers.keys {
        subscribers[id]?.needsKeyFrame = true
      }
    case .sample(_, let keyFrame):
      timeout?.cancel()
      for id in subscribers.keys where keyFrame {
        subscribers[id]?.needsKeyFrame = false
      }
    case .stopped:
      hasStopped = true
      timeout?.cancel()
    }
    for subscriber in Array(subscribers.values) {
      if case .sample = event, subscriber.needsKeyFrame { continue }
      subscriber.receive(event)
    }
  }

  private nonisolated static func readExactly(_ count: Int, from connection: ADBSocketConnection) throws -> Data {
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
