import Foundation

/// Each recording owns the Android audio sources it opens.
@MainActor
final class DeviceAudioConnection {
  private let target: DeviceTarget
  private let source: DeviceHelper.AudioSource
  private var task: Task<Void, Never>?

  init(target: DeviceTarget, source: DeviceHelper.AudioSource) {
    self.target = target
    self.source = source
  }

  func start(
    receive: @escaping @MainActor @Sendable (DeviceAudioPacket.Event) -> Void,
    failed: @escaping @MainActor @Sendable (Error) -> Void
  ) {
    task = Task.detached(priority: .userInitiated) { [target, source] in
      do {
        let helper = try DeviceHelper(DeviceHelper.bundledBytes())
        let session = try await helper.connect(.audio(source), serial: target.serial, adb: ADBClient().bound(to: target))
        let connection = session.connection
        defer { connection.close() }
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          guard session.header == DeviceAudioPacket.magic else { throw ADBError.protocolFailure("Unsupported device audio protocol") }
          var stream = session.stream
          while !Task.isCancelled {
            let packet = try connection.withRequestTimeout(.seconds(8)) {
              try DeviceAudioPacket.read { try stream.readExactly($0, read: connection.readChunk) }
            }
            await receive(packet)
          }
        } onCancel: { connection.close() }
      } catch {
        if !Task.isCancelled { await failed(error) }
      }
    }
  }

  func stop() {
    task?.cancel()
  }

  func waitUntilStopped() async {
    await task?.value
  }
}
