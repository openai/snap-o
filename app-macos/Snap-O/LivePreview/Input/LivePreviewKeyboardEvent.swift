import Foundation

enum LivePreviewKeyboardEvent: Equatable {
  case text(String)
  case key(code: UInt32, modifiers: UInt32 = 0)
  case paste(String)
  case copy
}

enum LivePreviewKeyboardResponse: Equatable {
  case sent
  case copied(String)
  case unsupportedText
}

@MainActor
protocol LivePreviewKeyboardHandling: AnyObject {
  func prepare()
  func discardPendingInput()
  func send(_ event: LivePreviewKeyboardEvent)
  func stop()
}
