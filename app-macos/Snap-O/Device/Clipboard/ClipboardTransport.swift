import Foundation

protocol ClipboardTransport: Sendable {
  func getText() async throws -> String
  func setText(_ text: String) async throws
  func receive(_ onText: @escaping @Sendable (String) async -> Void) async throws
}
