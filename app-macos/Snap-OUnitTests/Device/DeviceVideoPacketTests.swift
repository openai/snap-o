import Foundation
import Testing

struct DeviceVideoPacketTests {
  @Test
  func validatesDeviceVideoVersion() throws {
    try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56, 0x31]))
    #expect(throws: (any Error).self) { try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56, 0x32])) }
    #expect(throws: (any Error).self) { try DeviceVideoPacket.validateHeader(Data([0x53, 0x4E, 0x56])) }
  }

  @Test(arguments: DeviceVideoFailure.Stage.allCases, [false, true])
  func readsStructuredFailure(stage: DeviceVideoFailure.Stage, retryable: Bool) throws {
    let bytes = Data([3, stage.rawValue, retryable ? 1 : 0, 0x80, 0, 0x10, 1])
    guard case .failure(let failure) = try packet(bytes) else {
      Issue.record("Expected a video failure")
      return
    }
    #expect(failure == DeviceVideoFailure(stage: stage, retryable: retryable, codecError: -2_147_479_551))
    #expect(failure.localizedDescription.contains(stage.action))
    #expect(failure.localizedDescription.contains("-2147479551"))
  }

  @Test(arguments: [Data([3, 0, 0, 0, 0, 0, 0]), Data([3, 10, 0, 0, 0, 0, 0]), Data([3, 5, 2, 0, 0, 0, 0])])
  func rejectsInvalidFailureFields(bytes: Data) {
    #expect(throws: (any Error).self) { try packet(bytes) }
  }

  @Test(arguments: 0 ..< 7)
  func rejectsTruncatedFailure(length: Int) {
    #expect(throws: (any Error).self) { try packet(Data([3, 5, 0, 0, 0, 0, 0].prefix(length))) }
  }

  private func packet(_ bytes: Data) throws -> DeviceVideoPacket {
    var offset = 0
    return try DeviceVideoPacket.read { count in
      let end = min(offset + count, bytes.count)
      defer { offset = end }
      return bytes.subdata(in: offset ..< end)
    }
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
