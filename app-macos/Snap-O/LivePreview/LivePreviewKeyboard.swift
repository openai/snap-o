import AppKit
import Observation

protocol LivePreviewKeyboardTransport: Sendable {
  func send(_ event: LivePreviewKeyboardEvent) async throws -> String?
  func close()
}

@MainActor
@Observable
final class LivePreviewKeyboard: LivePreviewKeyboardHandling {
  var errorMessage: String?
  @ObservationIgnored private let connect: (String) async throws -> any LivePreviewKeyboardTransport
  @ObservationIgnored private let pasteboard: NSPasteboard
  @ObservationIgnored private let deviceID: String
  @ObservationIgnored private var pending: [(LivePreviewKeyboardEvent, Int)] = []
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var transport: (any LivePreviewKeyboardTransport)?

  init(
    deviceID: String,
    pasteboard: NSPasteboard = .general,
    connect: @escaping (String) async throws -> any LivePreviewKeyboardTransport = { try await DeviceKeyboardTransport.connect(serial: $0) }
  ) {
    self.deviceID = deviceID
    self.pasteboard = pasteboard
    self.connect = connect
  }

  func send(_ event: LivePreviewKeyboardEvent) {
    pending.append((event, pasteboard.changeCount))
    guard task == nil else { return }
    task = Task { await flush() }
  }

  func stop() {
    task?.cancel()
    task = nil
    transport?.close()
    transport = nil
    pending.removeAll()
  }

  private func flush() async {
    guard !Task.isCancelled else { return }
    defer { if !Task.isCancelled { task = nil } }
    do {
      if transport == nil {
        let connection = try await connect(deviceID)
        guard !Task.isCancelled else {
          connection.close()
          return
        }
        transport = connection
      }
      while !Task.isCancelled, !pending.isEmpty, let transport {
        let (event, changeCount) = pending.removeFirst()
        let copied = try await transport.send(event)
        guard !Task.isCancelled else { return }
        errorMessage = nil
        // A delayed device copy must not replace a newer copy in another Mac view.
        if let copied, pasteboard.changeCount == changeCount {
          pasteboard.clearContents()
          pasteboard.setString(copied, forType: .string)
        }
      }
    } catch {
      guard !Task.isCancelled else { return }
      stop()
      errorMessage = (error as? DeviceKeyboardError)?.message
        ?? "Couldn’t send keyboard input. Check the device connection."
    }
  }
}
