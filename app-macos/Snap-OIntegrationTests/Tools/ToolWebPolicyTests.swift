import Foundation
@testable import Snap_O
import Testing

@Suite("Tool web policy")
@MainActor
struct ToolWebPolicyTests {
  @Test("development URLs stay on loopback")
  func developmentURLs() {
    for valid in ["http://localhost:5173/", "https://127.0.0.1/dev", "http://[::1]:5173/", " http://localhost/\n"] {
      #expect(ToolWebPolicy.developmentURL(valid) != nil)
    }
    for invalid in [
      "",
      "https://example.com/",
      "file:///tmp/index.html",
      "http://user@localhost:1234/",
      "http://localhost:0/",
      "http://localhost:65536/"
    ] {
      #expect(ToolWebPolicy.developmentURL(invalid) == nil)
    }
  }

  @Test("API routes stay within the tool origin and namespace")
  func endpointURLs() throws {
    #expect(ToolURL.isAPI(ToolURL.api))
    for invalid in [
      "http://127.0.0.1:1234/api/", "snapo://other/api/", "snapo://tool:1234/api/",
      "snapo://user@tool/api/", "snapo://tool/index.html", "snapo://tool/apiary", "snapo://tool/api/#fragment"
    ] {
      let url = try #require(URL(string: invalid))
      #expect(!ToolURL.isAPI(url))
    }
  }

  @Test("generated allowlists match whole origins, not neighboring hosts or ports")
  func contentRules() throws {
    let asset = ToolURL.frontend
    let encoded = try ToolWebPolicy.contentRules(
      developmentURL: URL(string: "https://localhost:443/dev?q=1")
    )
    let rules = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: [String: String]]])
    #expect(rules.first == ["trigger": ["url-filter": ".*"], "action": ["type": "block"]])
    let allow = try rules.dropFirst().map { rule in
      #expect(rule["action"]?["type"] == "ignore-previous-rules")
      return try NSRegularExpression(pattern: #require(rule["trigger"]?["url-filter"]))
    }
    func permits(_ url: String) -> Bool {
      allow.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
    }
    for url in [
      "snapo://tool/api/events",
      "https://localhost/main.js",
      "wss://localhost/hmr",
      asset.absoluteString + "index.html",
      "data:text/plain,ok",
      "blob:fixture"
    ] {
      #expect(permits(url), "Expected allowance: \(url)")
    }
    for url in [
      "http://127.0.0.1:12345/data",
      "http://127x0x0x1:1234/data",
      "http://127.0.0.1:4321/",
      "https://localhost.example/",
      "https://localhost:444/",
      "file:///tmp/asset",
      "snapo://other/index.html",
      "snapo://tool.example/index.html",
      "snapo://tool:1234/api/events",
      "ws://127.0.0.1:1234/events"
    ] {
      #expect(!permits(url), "Unexpected allowance: \(url)")
    }
  }

  @Test("storage follows device, profile, package, and tool, but not process restarts")
  func storageScopes() throws {
    let first = selectionApp()
    let scope = try #require(ToolWebPolicy.storageIdentifier(app: first, tool: .sample))
    #expect(scope == ToolWebPolicy.storageIdentifier(app: selectionApp(20), tool: .sample))
    for other in [selectionApp(device: "tablet"), selectionApp(user: 10), selectionApp(package: "com.example.other")] {
      #expect(scope != ToolWebPolicy.storageIdentifier(app: other, tool: .sample))
    }
    #expect(scope != ToolWebPolicy.storageIdentifier(app: first, tool: .network))
    #expect(ToolWebPolicy.storageIdentifier(app: selectionApp(user: nil), tool: .sample) == nil)
    #expect(ToolWebPolicy.storageIdentifier(app: nil, tool: .sample) == nil)
  }

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

  @Test("toolbar validation rejects unsafe revisions and ambiguous actions")
  func toolbarValidation() throws {
    func toolbar(_ revision: Int = 1, actions: [[String: Any]]) throws -> ToolToolbar {
      try JSONDecoder().decode(ToolToolbar.self, from: JSONSerialization.data(withJSONObject: ["revision": revision, "actions": actions]))
    }
    let button: [String: Any] = ["id": "clear", "label": "Clear", "type": "button", "icon": "clear"]
    let search: [String: Any] = ["id": "search", "label": "Search", "type": "search"]
    try toolbar(actions: [button, search]).validate()
    for revision in [0, -1, Int(UInt32.max) + 1] {
      #expect(throws: ToolError.self) { try toolbar(revision, actions: [button]).validate() }
    }
    for actions in [
      [button, button],
      [search.merging(["inputRevision": Int.max]) { _, new in new }],
      [search.merging(["placement": "end"]) { _, new in new }],
      [button.filter { $0.key != "icon" }],
      (0 ..< 12).map { button.merging(["id": String($0), "placement": "end"]) { _, new in new } }
    ] {
      #expect(throws: ToolError.self) { try toolbar(actions: actions).validate() }
    }
  }
}
