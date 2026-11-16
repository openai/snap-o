import AVFoundation
import Foundation

/// Stereo PCM at 48 kHz. Each timestamp identifies the first sample on the device clock.
struct DeviceAudioPacket {
  static let magic = Data("SNA1".utf8)
  static let sampleRate: Int32 = 48000
  static let bytesPerFrame = 4
  let timestamp: CMTime
  let pcm: Data

  enum Event {
    case samples(DeviceAudioPacket)
    case microphoneSilenced(Bool)
  }

  static func read(from readBytes: (Int) throws -> Data) throws -> Event {
    func number(_ count: Int) throws -> UInt64 {
      let bytes = try readBytes(count)
      guard bytes.count == count else { throw ADBError.protocolFailure("Truncated device audio packet") }
      return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
    switch try number(1) {
    case 1:
      let micros = try number(8)
      let frames = try number(2)
      guard micros <= Int64.max, (1 ... 960).contains(frames) else {
        throw ADBError.protocolFailure("Invalid device audio packet")
      }
      let size = Int(frames) * bytesPerFrame
      let pcm = try readBytes(size)
      guard pcm.count == size else { throw ADBError.protocolFailure("Truncated device audio samples") }
      return .samples(Self(timestamp: CMTime(value: Int64(micros), timescale: 1_000_000), pcm: pcm))
    case 2:
      switch try number(1) {
      case 1: throw ADBError.protocolFailure("Recording device audio requires Android 13 or newer")
      case 2: throw ADBError.protocolFailure("Android could not start device audio capture")
      case 3: throw ADBError.protocolFailure("Android stopped delivering device audio")
      case 4: throw ADBError.protocolFailure("Android could not start the device microphone")
      default: throw ADBError.protocolFailure("Unknown device audio failure")
      }
    case 3:
      switch try number(1) {
      case 0: return .microphoneSilenced(false)
      case 1: return .microphoneSilenced(true)
      default: throw ADBError.protocolFailure("Invalid device microphone status")
      }
    default: throw ADBError.protocolFailure("Unknown device audio packet")
    }
  }

  static func makeFormat() throws -> CMAudioFormatDescription {
    var description = AudioStreamBasicDescription(
      mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16,
      mReserved: 0
    )
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    ) == noErr, let format else { throw ADBError.protocolFailure("Cannot create device audio format") }
    return format
  }

  func sample(format: CMAudioFormatDescription, startingAt origin: CMTime) throws -> CMSampleBuffer? {
    let frames = pcm.count / Self.bytesPerFrame
    // A packet may straddle the first video keyframe. Keep the samples inside the recording.
    let skip = CMTimeConvertScale(origin - timestamp, timescale: Self.sampleRate, method: .roundTowardPositiveInfinity)
    guard skip.value < frames else { return nil }
    let skipped = Int(max(0, skip.value))
    let offset = skipped * Self.bytesPerFrame
    let size = pcm.count - offset
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block
    ) == noErr, let block else { throw ADBError.protocolFailure("Cannot allocate device audio sample") }
    let copied = pcm.withUnsafeBytes { bytes in
      guard let address = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
      return CMBlockBufferReplaceDataBytes(with: address + offset, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
    }
    let start = timestamp + CMTime(value: Int64(skipped), timescale: Self.sampleRate)
    var sample: CMSampleBuffer?
    guard copied == noErr, CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames - skipped,
      presentationTimeStamp: start, packetDescriptions: nil, sampleBufferOut: &sample
    ) == noErr, let sample else { throw ADBError.protocolFailure("Cannot create device audio sample") }
    return sample
  }
}
