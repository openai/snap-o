import Dependencies
import Foundation
import Observation

/// Owns video startup and recovery. Input connections do not belong to this lifetime.
@Observable
@MainActor
final class PreviewVideo {
  enum Phase: Equatable {
    case idle, waitingForCleanup, starting, streaming, waitingToReconnect, failed(String), closed
  }

  private(set) var phase = Phase.idle
  private(set) var session: LivePreviewSession?
  private(set) var display: DisplayInfo?
  private let makeSession: @MainActor () async throws -> LivePreviewSession
  private let canReconnect: @MainActor () -> Bool
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var closing: Task<Void, Never>?
  @ObservationIgnored private var isClosed = false
  @ObservationIgnored private var isActive = true
  @Dependency(\.continuousClock)
  @ObservationIgnored private var clock

  init(
    makeSession: @escaping @MainActor () async throws -> LivePreviewSession,
    canReconnect: @escaping @MainActor () -> Bool
  ) {
    self.makeSession = makeSession
    self.canReconnect = canReconnect
  }

  func start() {
    guard work == nil else { return }
    restart()
  }

  func retry() {
    guard case .failed = phase else { return }
    restart()
  }

  func setActive(_ active: Bool) {
    guard !isClosed, isActive != active else { return }
    isActive = active
    if case .failed = phase { return }
    if active {
      restart()
    } else {
      work?.cancel()
      session?.cancel()
      phase = .idle
    }
  }

  func restart() {
    guard !isClosed, isActive else { return }
    let previous = work
    let retryStartup = session != nil
    previous?.cancel()
    session?.cancel()
    phase = previous == nil ? .starting : .waitingForCleanup
    work = Task {
      await previous?.value
      guard !isClosed, !Task.isCancelled else { return }
      await run(retryStartup: retryStartup)
    }
  }

  func close() async {
    if let closing { await closing.value
      return
    }
    isClosed = true
    phase = .closed
    work?.cancel()
    session?.cancel()
    let pending = work
    let closing = Task<Void, Never> { await pending?.value }
    self.closing = closing
    await closing.value
  }

  private struct Attempt {
    let opened: Bool
    let duration: Duration?
    let error: String?
  }

  private func run(retryStartup: Bool) async {
    let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3)]
    var retryIndex = 0
    var recovering = false
    var errorMessage = "Live preview is unavailable."
    while !isClosed, !Task.isCancelled {
      guard canReconnect() else { phase = .failed(errorMessage)
        return
      }
      if recovering {
        guard retryIndex < delays.count else { phase = .failed(errorMessage)
          return
        }
        phase = .waitingToReconnect
        do { try await clock.sleep(for: delays[retryIndex]) } catch { return }
        retryIndex += 1
        guard !isClosed, !Task.isCancelled else { return }
        guard canReconnect() else { phase = .failed(errorMessage)
          return
        }
      }
      phase = .starting
      let attempt = await runAttempt()
      guard !isClosed, !Task.isCancelled else { return }
      errorMessage = attempt.error ?? "Live preview disconnected."
      recovering = recovering || attempt.opened || retryStartup
      if let duration = attempt.duration, duration >= .seconds(10) { retryIndex = 0 }
      if !recovering { phase = .failed(errorMessage)
        return
      }
    }
  }

  private func runAttempt() async -> Attempt {
    let candidate: LivePreviewSession
    do {
      candidate = try await makeSession()
    } catch {
      return Attempt(opened: false, duration: nil, error: error.localizedDescription)
    }
    guard !isClosed, !Task.isCancelled else {
      candidate.cancel()
      _ = await candidate.waitUntilStop()
      return Attempt(opened: true, duration: nil, error: nil)
    }
    session = candidate
    candidate.displayDidChange = { [weak self, weak candidate] display in
      guard let self, let candidate, session === candidate, !isClosed else { return }
      self.display = display
    }
    if let ready = try? await candidate.waitUntilReady(), !isClosed, !Task.isCancelled {
      display = ready
      if candidate.isReady { phase = .streaming }
    }
    let error = await candidate.waitUntilStop()
    let duration = candidate.streamingDuration
    if session === candidate { session = nil }
    return Attempt(opened: true, duration: duration, error: error?.localizedDescription)
  }
}
