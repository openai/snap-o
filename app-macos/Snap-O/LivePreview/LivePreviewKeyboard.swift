import AppKit
import Observation

protocol LivePreviewKeyboardTransport: Sendable {
  func send(_ event: LivePreviewKeyboardEvent) async throws -> LivePreviewKeyboardResponse
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
  @ObservationIgnored private var inputRevision = 0
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

  func prepare() {
    guard task == nil, transport == nil || !pending.isEmpty else { return }
    task = Task { await flush() }
  }

  func send(_ event: LivePreviewKeyboardEvent) {
    pending.append((event, pasteboard.changeCount))
    prepare()
  }

  func discardPendingInput() {
    inputRevision += 1
    pending.removeAll()
  }

  func stop() {
    task?.cancel()
    task = nil
    transport?.close()
    transport = nil
    discardPendingInput()
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
        let revision = inputRevision
        let (event, changeCount) = pending.removeFirst()
        let response = try await transport.send(event)
        guard !Task.isCancelled else { return }
        // Finish the wire response, but ignore results from a previous keyboard focus.
        guard revision == inputRevision else { continue }
        switch response {
        case .sent:
          errorMessage = nil
        case .copied(let text):
          errorMessage = nil
          // A delayed device copy must not replace a newer copy in another Mac view.
          if pasteboard.changeCount == changeCount {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
          }
        case .unsupportedText:
          errorMessage = "Use Paste for characters Android can’t type."
        }
      }
    } catch {
      guard !Task.isCancelled else { return }
      stop()
      errorMessage = "Keyboard input unavailable. Check the device connection."
    }
  }
}
