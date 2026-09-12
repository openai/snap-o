import Foundation
@testable import Snap_O
import Testing
import ZIPFoundation

@Suite("Tool frontend archives")
struct ToolFrontendTests {
  private func archive(_ entries: [(String, Data)], type: Entry.EntryType = .file) throws -> Data {
    let archive = try Archive(accessMode: .create)
    for (name, data) in entries {
      try archive.addEntry(with: name, type: type, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
        data.subdata(in: Int(position) ..< Int(position) + count)
      }
    }
    return try #require(archive.data)
  }

  @Test("loads a standard compressed frontend with HTML and separate assets")
  func loadsAssets() throws {
    let files = [
      ("index.html", Data("<script src='./assets/main.js'></script>".utf8)),
      ("assets/main.js", Data("window.loaded = true".utf8))
    ]
    let bundle = try ToolFrontendBundle(archive: archive(files))
    #expect(bundle.files == Dictionary(uniqueKeysWithValues: files))
    #expect(bundle.entryPoint == "index.html")
  }

  @Test("rejects traversal, absolute paths, duplicate entries, and symlinks")
  func rejectsUnsafeEntries() throws {
    let html = ("index.html", Data("<p>Fixture</p>".utf8))
    for path in ["../escape.js", "/absolute.js", "assets/../../escape", "assets\\escape", "assets//file", "assets/./file", "index.html"] {
      let data = try archive([html, (path, Data("fixture".utf8))])
      #expect(throws: (any Error).self) { try ToolFrontendBundle(archive: data) }
    }
    let link = try archive([("index.html", Data("/tmp/other".utf8))], type: .symlink)
    #expect(throws: (any Error).self) { try ToolFrontendBundle(archive: link) }
  }

  @Test("requires a UTF-8 index.html at the archive root")
  func requiresEntryPoint() throws {
    for entries in [[("dist/index.html", Data("fixture".utf8))], [("index.html", Data([0xFF]))]] {
      let data = try archive(entries)
      #expect(throws: (any Error).self) { try ToolFrontendBundle(archive: data) }
    }
  }

  @Test("bounds decompressed data and the number of entries")
  func boundsExpansion() throws {
    let oversized = try archive([("index.html", Data("fixture".utf8)), ("large.bin", Data(repeating: 0, count: 16 * 1024 * 1024))])
    #expect(throws: (any Error).self) { try ToolFrontendBundle(archive: oversized) }
    let many = try archive((0 ..< 1025).map { ("file\($0)", Data()) })
    #expect(throws: (any Error).self) { try ToolFrontendBundle(archive: many) }
    #expect(throws: (any Error).self) { try ToolFrontendBundle(archive: Data("not a ZIP".utf8)) }
  }

  @Test("frontend requests are tied to the discovered package and tool")
  func requestsExpectedPackage() throws {
    let manifest = try JSONDecoder().decode(
      ToolProcessMetadata.self,
      from: Data(
        #"{"version":1,"pid":42,"processIdentity":"boot:42:1","androidUserId":0,"app":{"packageName":"com.example.demo","name":"Demo","revision":"12:34","inspectors":[{"id":"sample","name":"Sample","protocolVersion":1,"frontend":{"assetPath":"snapo/inspectors/sample/frontend.zip","hostApiVersion":1}}]}}"#
          .utf8
      )
    )
    let tool = try #require(manifest.app?.tools.first)
    let request = try ToolFrontendBundle.request(manifest: manifest, tool: tool)
    let fields = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
    #expect(fields["inspectorId"] as? String == "sample")
    #expect(fields["toolId"] == nil)
    let encodedManifest = try JSONEncoder().encode(manifest)
    let decodedManifest = try #require(JSONSerialization.jsonObject(with: encodedManifest) as? [String: Any])
    let app = try #require(decodedManifest["app"] as? [String: Any])
    #expect((app["inspectors"] as? [[String: Any]])?.first?["id"] as? String == "sample")
    #expect(app["tools"] == nil)
    let identity = try #require(ToolProcessIdentity(metadata: manifest))
    let normalizedRequest = try ToolFrontendBundle.request(identity: identity, tool: tool)
    let normalizedFields = try #require(JSONSerialization.jsonObject(with: normalizedRequest) as? NSDictionary)
    #expect(normalizedFields == fields as NSDictionary)
    #expect(fields["androidUserId"] as? Int == 0)
    #expect(fields["packageName"] as? String == "com.example.demo")
    #expect(fields["revision"] as? String == "12:34")
    #expect(fields["processIdentity"] as? String == "boot:42:1")
    #expect(fields["assetPath"] as? String == "snapo/inspectors/sample/frontend.zip")
    let command = try ToolManifestReader.command(
      helper: Data("fixture".utf8),
      socketNames: ["snapo_sample_42"],
      frontendRequest: request
    )
    #expect(command.contains("com.openai.snapo.discovery.FrontendMain snapo_sample_42"))
    #expect(command.contains(request.base64EncodedString()))
    let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
    for (key, invalid) in [("androidUserId", NSNull()), ("androidUserId", -1), ("processIdentity", " "), ("pid", 0)] as [(String, Any)] {
      var value = original
      value[key] = invalid
      let incomplete = try JSONDecoder().decode(ToolProcessMetadata.self, from: JSONSerialization.data(withJSONObject: value))
      #expect(ToolProcessIdentity(metadata: incomplete) == nil)
      #expect(throws: (any Error).self) { try ToolFrontendBundle.request(manifest: incomplete, tool: tool) }
    }
  }
}
