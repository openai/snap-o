import AppKit

@MainActor
protocol TextPasteboard: AnyObject {
  var changeCount: Int { get }
  var hasItems: Bool { get }
  var text: String? { get }
  func replaceText(_ text: String)
}

extension NSPasteboard: TextPasteboard {
  var hasItems: Bool {
    pasteboardItems?.isEmpty == false
  }

  var text: String? {
    string(forType: .string)
  }

  func replaceText(_ text: String) {
    clearContents()
    setString(text, forType: .string)
  }
}
