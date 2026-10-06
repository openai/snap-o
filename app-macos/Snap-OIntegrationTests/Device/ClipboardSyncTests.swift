import AppKit
@testable import Snap_O
import Testing

struct ClipboardSyncTests {
  @MainActor
  @Test
  func initialSnapshotPreservesUnsupportedPasteboardItems() throws {
    let suite = "SnapOClipboardTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pasteboard = NSPasteboard(name: .init(suite))
    defer { pasteboard.releaseGlobally() }
    let items: [(NSPasteboard.PasteboardType, Data)] = [
      (.tiff, Data([0x49, 0x49, 0x2A, 0])),
      (.fileURL, Data("file:///tmp/synthetic.txt".utf8)),
      (.string, Data()),
      (.string, Data(repeating: 65, count: ClipboardSyncState.maximumTextBytes + 1))
    ]
    for (type, data) in items {
      pasteboard.clearContents()
      #expect(pasteboard.setData(data, forType: type))
      let changeCount = pasteboard.changeCount
      let sync = ClipboardSync(settings: AppSettings(defaults: defaults), pasteboard: pasteboard)
      #expect(sync.synchronizeInitialClipboard(with: "Old emulator text") == nil)
      sync.receive("Old emulator text")
      #expect(pasteboard.changeCount == changeCount)
      #expect(pasteboard.data(forType: type) == data)
      sync.receive("New emulator copy")
      #expect(pasteboard.string(forType: .string) == "New emulator copy")
    }
  }

  @MainActor
  @Test
  func initialSyncImportsOnlyIntoAnEmptyPasteboard() throws {
    let suite = "SnapOClipboardTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let pasteboard = NSPasteboard(name: .init(suite))
    defer { pasteboard.releaseGlobally() }
    let settings = AppSettings(defaults: defaults)
    let sync = ClipboardSync(settings: settings, pasteboard: pasteboard)
    #expect(sync.synchronizeInitialClipboard(with: "Emulator text") == nil)
    #expect(pasteboard.string(forType: .string) == "Emulator text")

    pasteboard.clearContents()
    pasteboard.setString("Mac text", forType: .string)
    let nextSync = ClipboardSync(settings: settings, pasteboard: pasteboard)
    #expect(nextSync.synchronizeInitialClipboard(with: "Old emulator text") == "Mac text")
    #expect(pasteboard.string(forType: .string) == "Mac text")
  }

  @MainActor
  @Test
  func refreshesJWTBeforeExpiryAndReusesStaticTokens() async throws {
    let now = Date(timeIntervalSince1970: 1000)
    var refreshes = 0
    let authentication = EmulatorClipboardAuthentication(
      endpoint: EmulatorGRPCEndpoint(port: 8554, token: "initial", expiresAt: now.addingTimeInterval(900))
    ) {
      refreshes += 1
      return EmulatorGRPCEndpoint(port: 8554, token: "renewed", expiresAt: now.addingTimeInterval(1800))
    }
    #expect(try await authentication.token(at: now) == "initial")
    #expect(refreshes == 0)
    #expect(try await authentication.token(at: now.addingTimeInterval(840)) == "renewed")
    #expect(try await authentication.token(at: now.addingTimeInterval(950)) == "renewed")
    #expect(refreshes == 1)
    let staticAuthentication = EmulatorClipboardAuthentication(endpoint: EmulatorGRPCEndpoint(port: 8554, token: "static")) {
      Issue.record("Static tokens do not need renewal")
      throw CancellationError()
    }
    #expect(try await staticAuthentication.token(at: now.addingTimeInterval(3600)) == "static")
  }

  @MainActor
  @Test
  func rejectsChangedEndpointsAndMissingAuthentication() async {
    let authentication = EmulatorClipboardAuthentication(
      endpoint: EmulatorGRPCEndpoint(port: 8554, token: "initial", expiresAt: .distantPast)
    ) { EmulatorGRPCEndpoint(port: 8555, token: "other-emulator") }
    await #expect(throws: AndroidHostClientError.self) { try await authentication.token() }
    let unauthenticated = EmulatorClipboardAuthentication(endpoint: EmulatorGRPCEndpoint(port: 8554, token: nil)) {
      throw CancellationError()
    }
    await #expect(throws: AndroidHostClientError.self) { try await unauthenticated.token() }
  }
}
