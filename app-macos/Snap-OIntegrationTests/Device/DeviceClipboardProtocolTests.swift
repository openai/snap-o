import Foundation
@testable import Snap_O
import Testing

struct DeviceClipboardProtocolTests {
  @Test(arguments: [
    Data([0xFF, 0xFF, 0xFF, 0xFF]),
    Data([0, 0x10, 0, 1]),
    Data([0, 0, 0, 2, 0xC3, 0x28]),
    Data([0, 0, 0, 10, 1]),
    Data([0, 0])
  ])
  func rejectsMalformedFrames(_ frame: Data) {
    var reader = ByteReader(frame)
    #expect(throws: ADBError.self) { try DeviceClipboardProtocol.readText(read: { reader.read($0) }) }
  }

  @Test(arguments: ["", "selection 😀"])
  func readsFragmentedFrames(_ text: String) throws {
    var reader = try ByteReader(DeviceClipboardProtocol.frame(text))
    #expect(try DeviceClipboardProtocol.readText(read: { reader.read($0) }) == text)
    #expect(reader.bytes.isEmpty)
  }

  @Test
  func rejectsOversizedLengthBeforeReadingPayload() {
    var calls = 0
    #expect(throws: ADBError.self) {
      try DeviceClipboardProtocol.readText { count in
        calls += 1
        #expect(count == 4)
        return Data([0, 0x10, 0, 1])
      }
    }
    #expect(calls == 1)
  }
}

private struct ByteReader {
  var bytes: Data

  init(_ bytes: Data) {
    self.bytes = bytes
  }

  mutating func read(_ count: Int) -> Data? {
    guard !bytes.isEmpty else { return nil }
    let chunk = Data(bytes.prefix(min(count, 1)))
    bytes.removeFirst(chunk.count)
    return chunk
  }
}
