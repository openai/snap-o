import Foundation
import Testing

struct DeviceVideoPacketTests {
  @Test
  func validatesDeviceVideoVersion() throws {
    try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56, 0x31]))
    #expect(throws: (any Error).self) { try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56, 0x32])) }
    #expect(throws: (any Error).self) { try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56])) }
  }

  @Test
  func rejectsOversizedPacketsBeforeReadingTheirPayload() throws {
    var bytes = Data([2, 0, 0, 0, 1])
    bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
    bytes.append(contentsOf: [1, 0, 0, 1])
    var offset = 0
    #expect(throws: (any Error).self) {
      try DeviceVideoPacket.read { count in
        guard offset + count <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
        defer { offset += count }
        return bytes.subdata(in: offset ..< offset + count)
      }
    }
    #expect(offset == 17)
  }

  @Test
  func splitsMixedStartCodesWithoutInventingFrames() throws {
    let units = try DeviceVideoSampleBuilder.nalUnits(Data([0, 0, 0, 1, 0x67, 5, 0, 0, 1, 0x68, 7]))
    #expect(units == [Data([0x67, 5]), Data([0x68, 7])])
    #expect(throws: (any Error).self) { try DeviceVideoSampleBuilder.nalUnits(Data([0, 0, 1])) }
  }
}
