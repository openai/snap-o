import Dependencies
import Foundation
import Observation

/// Controls the temporary thumbnail strip, independently of the items it displays.
@Observable
@MainActor
final class PreviewHint {
  private(set) var isVisible = false
  private var isHovered = false
  @ObservationIgnored private var hideTask: Task<Void, Never>?
  @Dependency(\.continuousClock)
  @ObservationIgnored private var clock

  func show(available: Bool, transient: Bool) {
    guard available else { cancel(); return }
    hideTask?.cancel()
    hideTask = nil
    isVisible = true
    if transient { hide(after: .seconds(2)) }
  }

  func setHovered(_ hovered: Bool) {
    isHovered = hovered
    if hovered {
      hideTask?.cancel()
      hideTask = nil
    } else if isVisible {
      hide(after: .milliseconds(500))
    }
  }

  func cancel() {
    hideTask?.cancel()
    hideTask = nil
    isVisible = false
    isHovered = false
  }

  private func hide(after delay: Duration) {
    hideTask?.cancel()
    hideTask = Task { [weak self, clock] in
      do { try await clock.sleep(for: delay) } catch { return }
      guard let self, !isHovered else { return }
      isVisible = false
      hideTask = nil
    }
  }
}
