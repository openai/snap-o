import AVFoundation
import Foundation
import Testing

struct DeviceAudioPacketTests {
  @Test(arguments: ["phone", "emulator-5554"], [32, 33, 37])
  func offersDeviceAudioOnSupportedAndroidVersions(serial: String, sdk: Int) {
    let device = Device(
      id: serial, model: "Test", androidVersion: "Preview", androidSDK: sdk,
      vendorModel: nil, manufacturer: nil, avdName: nil
    )
    #expect(device.supportsDeviceAudioRecording == (sdk >= 33))
  }

  @Test
  func keepsSamplesAtAndAfterTheFirstVideoKeyframe() throws {
    let origin = CMTime(value: 3_200_000_000, timescale: 1_000_000)
    let pcm = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    var wire = Data([1])
    withUnsafeBytes(of: UInt64(origin.value).bigEndian) { wire.append(contentsOf: $0) }
    wire.append(contentsOf: [0, 3])
    wire.append(pcm)
    guard case .samples(let packet) = try read(wire) else {
      Issue.record("Expected an audio sample packet")
      return
    }
    let format = try DeviceAudioPacket.makeFormat()
    let frame = CMTime(value: 1, timescale: DeviceAudioPacket.sampleRate)
    let sample = try #require(try packet.sample(format: format, startingAt: origin + frame))
    #expect(CMSampleBufferGetNumSamples(sample) == 2)
    #expect(CMSampleBufferGetPresentationTimeStamp(sample) == origin + frame)
    #expect(CMSampleBufferGetDuration(sample) == frame + frame)
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var samples = [UInt8](repeating: 0, count: 8)
    #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count, destination: &samples) == noErr)
    #expect(samples == Array(pcm.dropFirst(4)))
    #expect(try packet.sample(format: format, startingAt: origin + frame + frame + frame) == nil)
  }

  private static let invalidPackets: [Data] = [
    Data([1]), Data([2, 1]), Data([2, 2]), Data([2, 3]), Data([2, 4]), Data([3]), Data([3, 2]), Data([9]),
    Data([1] + Array(repeating: 0, count: 8) + [3, 193]),
    Data([1] + Array(repeating: 0, count: 8) + [0, 1, 0, 1])
  ]

  @Test(arguments: invalidPackets)
  func rejectsFailuresAndMalformedPackets(bytes: Data) {
    #expect(throws: (any Error).self) { try read(bytes) }
  }

  @Test(arguments: [UInt8(0), 1])
  func readsAndroidMicrophoneSharingStatus(value: UInt8) throws {
    guard case .microphoneSilenced(let silenced) = try read(Data([3, value])) else {
      Issue.record("Expected Android microphone status")
      return
    }
    #expect(silenced == (value == 1))
  }

  private func read(_ data: Data) throws -> DeviceAudioPacket.Event {
    var bytes = data[...]
    return try DeviceAudioPacket.read { count in
      let part = bytes.prefix(count)
      bytes = bytes.dropFirst(part.count)
      return Data(part)
    }
  }
}
