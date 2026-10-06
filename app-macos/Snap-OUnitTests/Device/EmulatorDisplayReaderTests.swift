import Foundation
import Testing

struct EmulatorDisplayReaderTests {
  @Test
  func keepsFirstReply() throws {
    let provider = DisplayReplies(values: [("1080x2400", nil), (nil, "late failure")])
    #expect(try EmulatorDisplayReader(provider: provider).read() == "1080x2400")
  }

  @Test(arguments: [false, true])
  func reportsProviderErrorEvenWithAValue(hasValue: Bool) {
    let provider = DisplayReplies(values: [(hasValue ? "1080x2400" : nil, "Connection changed")])
    #expect(throws: (any Error).self) {
      do {
        _ = try EmulatorDisplayReader(provider: provider).read()
      } catch {
        #expect(error.localizedDescription == "Connection changed")
        throw error
      }
    }
  }

  @Test
  func rejectsMissingValueAndError() {
    let provider = DisplayReplies(values: [(nil, nil)])
    #expect(throws: AndroidHostServiceError.self) {
      try EmulatorDisplayReader(provider: provider).read()
    }
  }
}

private final class DisplayReplies: NSObject, EmulatorDisplayProvider, Sendable {
  let values: [(String?, String?)]

  init(values: [(String?, String?)]) {
    self.values = values
  }

  func readDisplay(reply: @escaping @Sendable (String?, String?) -> Void) {
    for (value, error) in values {
      reply(value, error)
    }
  }
}
