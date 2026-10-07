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

  @Test(arguments: [Data([3, 0, 0, 0, 0, 0, 0]), Data([3, 11, 0, 0, 0, 0, 0]), Data([3, 5, 2, 0, 0, 0, 0])])
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

  private let redPixels = Data([120, 1, 251, 207, 192, 240, 255, 63, 18, 6, 0, 67, 204, 7, 249])

  private func rgbaPacket(_ payload: Data, width: UInt32 = 2, height: UInt32 = 2) -> Data {
    var bytes = Data([4])
    for value in [width, height, 0, 123, UInt32(payload.count)] {
      withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
    bytes.append(payload)
    return bytes
  }

  @Test
  func decompressesRGBAWithoutChangingPixels() throws {
    guard case .rgba(let width, let height, let timestamp, let pixels) = try packet(rgbaPacket(redPixels)) else {
      Issue.record("Expected an RGBA frame")
      return
    }
    #expect(width == 2 && height == 2 && timestamp == 123)
    #expect(pixels == Data(Array(repeating: [UInt8(255), 0, 0, 255], count: 4).flatMap(\.self)))
  }

  @Test
  func rejectsInvalidCompressedRGBA() {
    var corrupt = redPixels
    corrupt[corrupt.count - 1] ^= 1
    for payload in [Data(redPixels.dropLast()), redPixels + Data([0]), corrupt, Data()] {
      #expect(throws: (any Error).self) { try packet(rgbaPacket(payload)) }
    }
    #expect(throws: (any Error).self) { try packet(rgbaPacket(redPixels, width: 3)) }
    #expect(throws: (any Error).self) { try packet(rgbaPacket(redPixels, width: 8192, height: 8192)) }
    let complete = rgbaPacket(redPixels)
    for length in 0 ..< complete.count {
      #expect(throws: (any Error).self) { try packet(Data(complete.prefix(length))) }
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
