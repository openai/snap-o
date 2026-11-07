import Foundation
import Testing

struct ADBShellV2StreamTests {
  @Test(arguments: [1, 2, 5, 64])
  func readsStdoutAcrossPacketsAndFragmentedReads(fragment: Int) throws {
    var wire = packet(2, Data("diagnostic".utf8)) + packet(1, Data([0, 255]))
      + packet(1, Data()) + packet(2, Data([42])) + packet(1, Data([13, 10, 1, 2]))
    var stream = ADBShellV2Stream()
    func read(_ count: Int) -> Data? {
      guard !wire.isEmpty else { return nil }
      let bytes = Data(wire.prefix(min(count, fragment)))
      wire.removeFirst(bytes.count)
      return bytes
    }
    #expect(try stream.readExactly(4, read: read) == Data([0, 255, 13, 10]))
    #expect(try stream.readExactly(2, read: read) == Data([1, 2]))
    #expect(wire.isEmpty)
  }

  @Test
  func wrapsBinaryInputWithLittleEndianLength() throws {
    #expect(try ADBShellV2Stream.standardInput(Data([1])) == Data([0, 1, 0, 0, 0, 1]))
    let input = Data(repeating: 255, count: 256)
    #expect(try ADBShellV2Stream.standardInput(input) == Data([0, 0, 1, 0, 0]) + input)
    #expect(throws: (any Error).self) {
      try ADBShellV2Stream.standardInput(Data(count: 1024 * 1024 + 1))
    }
  }

  @Test(arguments: [UInt8(0), 1, 255])
  func reportsExitStatus(status: UInt8) {
    var bytes = packet(3, Data([status]))
    var stream = ADBShellV2Stream()
    do {
      _ = try stream.readExactly(1) { count in
        defer { bytes.removeFirst(min(count, bytes.count)) }
        return Data(bytes.prefix(count))
      }
      Issue.record("Expected the shell exit status")
    } catch {
      #expect(error.localizedDescription.contains("status \(status)"))
    }
  }

  @Test(arguments: [
    Data(), Data([1, 2]), Data([1, 2, 0, 0, 0, 42]),
    Data([1, 1, 0, 16, 0]), Data([9, 0, 0, 0, 0]), Data([3, 0, 0, 0, 0])
  ])
  func rejectsTruncatedOversizedAndInvalidPackets(bytes: Data) {
    var wire = bytes
    var stream = ADBShellV2Stream()
    #expect(throws: (any Error).self) {
      try stream.readExactly(1) { count in
        defer { wire.removeFirst(min(count, wire.count)) }
        return Data(wire.prefix(count))
      }
    }
  }

  private func packet(_ channel: UInt8, _ payload: Data) -> Data {
    var bytes = Data([channel])
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) { bytes.append(contentsOf: $0) }
    return bytes + payload
  }
}
