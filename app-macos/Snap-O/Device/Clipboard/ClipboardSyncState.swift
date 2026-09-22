struct ClipboardSyncState {
  static let maximumTextBytes = 1_048_576

  private(set) var changeCount: Int?
  private(set) var lastText: String?
  private var ignoredInitialText: String?

  mutating func ignoreInitialSnapshot(matching text: String) {
    ignoredInitialText = text
  }

  mutating func hostText(_ text: String?, changeCount: Int) -> String? {
    guard self.changeCount != changeCount else { return nil }
    self.changeCount = changeCount
    guard let text, Self.canSync(text), text != lastText else { return nil }
    lastText = text
    return text
  }

  mutating func shouldReceive(_ text: String, hostChangeCount: Int) -> Bool {
    // Some emulators omit an empty initial snapshot. Preserve the first real copy in that case.
    let ignoredText = ignoredInitialText
    ignoredInitialText = nil
    guard text != ignoredText else { return false }
    // A copy made on the Mac while an RPC was in flight takes precedence over its reply.
    return changeCount == hostChangeCount && Self.canSync(text) && text != lastText
  }

  mutating func received(_ text: String, changeCount: Int) {
    self.changeCount = changeCount
    lastText = text
  }

  private static func canSync(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= maximumTextBytes
  }
}
