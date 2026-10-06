import Foundation
@testable import Snap_O
import Testing

@MainActor
struct ToolBridgeValidationTests {
  @Test("bridge messages have command, size, depth, and collection limits")
  func messageLimits() {
    #expect(ToolWebBridge.validMessage(["command": "hostState"], command: "hostState"))
    #expect(!ToolWebBridge.validMessage(["command": "unknown"], command: "unknown"))
    #expect(!ToolWebBridge.validMessage(["payload": String(repeating: "x", count: 1_048_577)], command: "copyText"))
    #expect(!ToolWebBridge.validMessage(["payload": Array(repeating: "x", count: 65)], command: "setToolbar"))
    var nested: Any = "value"
    for _ in 0 ..< 10 {
      nested = ["nested": nested]
    }
    #expect(!ToolWebBridge.validMessage(["payload": nested], command: "setToolbar"))
  }
}
