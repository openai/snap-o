import Foundation
#if canImport(Snap_O) && !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif

@MainActor
final class TextPasteboardDouble: TextPasteboard {
  private(set) var changeCount = 0
  private(set) var hasItems = false
  private(set) var text: String?

  func replaceText(_ text: String) {
    self.text = text
    hasItems = true
    changeCount += 1
  }

  func setUnsupportedContent() {
    text = nil
    hasItems = true
    changeCount += 1
  }
}
