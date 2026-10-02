import AppKit
import Testing

struct HeadlessTestHostTests {
  @Test @MainActor
  func runsWithoutAnApplicationHost() {
    #expect(NSApp == nil)
    #expect(Bundle.main.bundleURL.pathExtension != "app")
  }
}
