import AppKit
import Darwin
import Testing

@main
struct PreviewInputTests {
  @MainActor
  static func main() async {
    if ProcessInfo.processInfo.environment["SNAPO_TEST_WINDOWS"] == "1" {
      runWindowTests()
    } else {
      let result: CInt = await Testing.__swiftPMEntryPoint()
      exit(result)
    }
  }

  @MainActor
  private static func runWindowTests() {
    let app = NSApplication.shared
    Task {
      let result: CInt = await Testing.__swiftPMEntryPoint()
      exit(result)
    }
    app.run()
  }
}
