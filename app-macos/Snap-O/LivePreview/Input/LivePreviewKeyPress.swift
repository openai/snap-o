import Foundation

/// The current control owns release of each held Android key.
struct LivePreviewKeyPress {
  private var owners: [UInt32: UUID] = [:]

  mutating func setPressed(_ pressed: Bool, code: UInt32, source: UUID) -> LivePreviewKeyboardEvent? {
    if pressed {
      return owners.updateValue(source, forKey: code) == nil ? .keyDown(code: code) : nil
    }
    guard owners[code] == source else { return nil }
    owners.removeValue(forKey: code)
    return .keyUp(code: code)
  }

  mutating func reset() {
    owners.removeAll()
  }
}
