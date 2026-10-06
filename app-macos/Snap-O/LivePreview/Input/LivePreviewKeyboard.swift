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
  @ObservationIgnored private let target: DeviceTarget?
  @ObservationIgnored private let deviceID: String
  @ObservationIgnored private var pending: [(LivePreviewKeyboardEvent, Int)] = []
  @ObservationIgnored private var inputRevision = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var isStopped = false
  @ObservationIgnored private var cleanupTask: Task<Void, Never>?
  @ObservationIgnored private var shutdownTask: Task<Void, Never>?
  @ObservationIgnored private var transport: (any LivePreviewKeyboardTransport)?

  init(
    deviceID: String,
    target: DeviceTarget? = nil,
    pasteboard: NSPasteboard = .general,
    connect: @escaping (String) async throws -> any LivePreviewKeyboardTransport
  ) {
    self.target = target
    self.deviceID = deviceID
    self.pasteboard = pasteboard
    self.connect = connect
  }

  func prepare() {
    guard !isStopped else { return }
    guard target?.isValid != false else { stop()
      return
    }
    guard task == nil, transport == nil || !pending.isEmpty else { return }
    task = Task { await flush() }
  }

  func send(_ event: LivePreviewKeyboardEvent) {
    guard !isStopped else { return }
    pending.append((event, pasteboard.changeCount))
    prepare()
  }

  func discardPendingInput() {
    inputRevision += 1
    pending.removeAll()
  }

  /// Revoke queued input now; the returned task finishes the current wire response.
  @discardableResult
  func releaseInput() -> Task<Void, Never> {
    discardPendingInput()
    return task ?? Task {}
  }

  func stop() {
    let pendingTask = task
    pendingTask?.cancel()
    task = nil
    transport?.close()
    transport = nil
    discardPendingInput()
    if let pendingTask {
      let previous = cleanupTask
      cleanupTask = Task {
        await previous?.value
        await pendingTask.value
      }
    }
  }

  @discardableResult
  func beginShutdown() -> Task<Void, Never> {
    if let shutdownTask { return shutdownTask }
    isStopped = true
    stop()
    let task = cleanupTask ?? Task {}
    shutdownTask = task
    return task
  }

  private func flush() async {
    guard !Task.isCancelled else { return }
    guard target?.isValid != false else { stop()
      return
    }
    defer {
      if !Task.isCancelled {
        task = nil
        if !pending.isEmpty { prepare() }
      }
    }
    var revision = inputRevision
    do {
      if transport == nil {
        let connection = try await connect(deviceID)
        guard !Task.isCancelled, target?.isValid != false else {
          connection.close()
          if !Task.isCancelled { stop() }
          return
        }
        transport = connection
      }
      while !Task.isCancelled, target?.isValid != false, !pending.isEmpty, let transport {
        revision = inputRevision
        let (event, changeCount) = pending.removeFirst()
        let response = try await transport.send(event)
        guard !Task.isCancelled else { return }
        guard target?.isValid != false else { stop()
          return
        }
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
      guard target?.isValid != false else { stop()
        return
      }
      if revision != inputRevision {
        // Retry only unsent input from the new focus, never the failed event.
        transport?.close()
        transport = nil
        return
      }
      stop()
      errorMessage = "Keyboard input unavailable. Check the device connection."
    }
  }
}
