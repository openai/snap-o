import Foundation
@testable import Snap_O
import Testing

struct KeyboardWireFormatTests {
  @Test
  func wireFramesPreserveLiteralTextAndRejectOversize() throws {
    let text = "quotes '\"; $HOME `literal` %s\n😀"
    let bytes = Data(text.utf8)
    let frame = try DeviceKeyboardTransport.frame(.paste(text))
    #expect(frame.prefix(4) == Data([0, 0, 0, 3]))
    #expect(frame.dropFirst(8) == bytes)
    #expect(try DeviceKeyboardTransport.frame(.copy) == Data([0, 0, 0, 4]))
    #expect(try DeviceKeyboardTransport.frame(.key(code: 21, modifiers: 1)) == Data([0, 0, 0, 2, 0, 0, 0, 21, 0, 0, 0, 1]))
    #expect(throws: (any Error).self) {
      try DeviceKeyboardTransport.frame(.paste(String(repeating: "x", count: 1_048_577)))
    }
  }
}
