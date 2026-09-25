@preconcurrency import AVFoundation
import Foundation

/// The helper sends complete AVC access units, including their device timestamps.
enum DeviceVideoPacket {
  case display(width: Int, height: Int, density: Int, rotation: Int)
  case frame(flags: UInt32, timestamp: Int64, data: Data)

  static let maximumBytes = 16 * 1024 * 1024

  static func read(from readBytes: (Int) throws -> Data) throws -> Self {
    func number(_ count: Int) throws -> UInt64 {
      try readBytes(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    switch try number(1) {
    case 1:
      let width = try Int(number(4))
      let height = try Int(number(4))
      let density = try Int(number(4))
      let rotation = try Int(number(4))
      guard (2 ... 8192).contains(width), (2 ... 8192).contains(height),
            (1 ... 4096).contains(density), (0 ... 3).contains(rotation) else {
        throw ADBError.protocolFailure("Invalid video display metadata")
      }
      return .display(width: width, height: height, density: density, rotation: rotation)
    case 2:
      let flags = try UInt32(number(4))
      let timestamp = try number(8)
      let count = try Int(number(4))
      guard count > 0, count <= maximumBytes, timestamp <= Int64.max, flags & ~UInt32(7) == 0 else {
        throw ADBError.protocolFailure("Invalid video packet")
      }
      return try .frame(flags: flags, timestamp: Int64(timestamp), data: readBytes(count))
    default:
      throw ADBError.protocolFailure("Unknown video packet")
    }
  }
}

/// Builds compressed samples without guessing frame boundaries or presentation times.
struct DeviceVideoSampleBuilder {
  private(set) var format: CMVideoFormatDescription?
  private var sps: Data?
  private var pps: Data?

  mutating func reset() {
    format = nil
    sps = nil
    pps = nil
  }

  mutating func sample(data: Data, timestamp: Int64, flags: UInt32) throws -> CMSampleBuffer? {
    let units = try Self.nalUnits(data)
    var video: [Data] = []
    for unit in units {
      switch unit[unit.startIndex] & 0x1F {
      case 7: sps = unit
      case 8: pps = unit
      default: video.append(unit)
      }
    }
    if format == nil, let sps, let pps {
      var description: CMVideoFormatDescription?
      let status = sps.withUnsafeBytes { first in
        pps.withUnsafeBytes { second in
          guard let firstPointer = first.baseAddress?.assumingMemoryBound(to: UInt8.self),
                let secondPointer = second.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            return kCMFormatDescriptionError_InvalidParameter
          }
          return CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: 2,
            parameterSetPointers: [firstPointer, secondPointer],
            parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
            formatDescriptionOut: &description
          )
        }
      }
      guard status == noErr else { throw ADBError.protocolFailure("Invalid AVC configuration") }
      format = description
    }
    guard flags & 2 == 0, !video.isEmpty else { return nil }
    guard let format else { throw ADBError.protocolFailure("Video arrived before AVC configuration") }
    var bytes = Data()
    for unit in video {
      var length = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
      bytes.append(unit)
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
      blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
      flags: 0, blockBufferOut: &block
    ) == noErr, let block else { throw ADBError.protocolFailure("Cannot allocate video sample") }
    let copied = bytes.withUnsafeBytes { buffer in
      guard let pointer = buffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
      return CMBlockBufferReplaceDataBytes(with: pointer, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
    }
    guard copied == noErr else { throw ADBError.protocolFailure("Cannot copy video sample") }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000),
      decodeTimeStamp: .invalid
    )
    var size = bytes.count
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
    ) == noErr, let sample else { throw ADBError.protocolFailure("Cannot create video sample") }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      // Device uptime is not the Mac's display clock. MP4 still uses the original sample timestamp.
      CFDictionarySetValue(
        entry,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
      CFDictionarySetValue(
        entry,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(flags & 1 == 0 ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
      )
    }
    return sample
  }

  static func nalUnits(_ data: Data) throws -> [Data] {
    let bytes = [UInt8](data)
    var starts: [(Int, Int)] = []
    var index = 0
    while index + 2 < bytes.count {
      if bytes[index] == 0, bytes[index + 1] == 0 {
        if bytes[index + 2] == 1 {
          starts.append((index, index + 3))
          index += 3
          continue
        }
        if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
          starts.append((index, index + 4))
          index += 4
          continue
        }
      }
      index += 1
    }
    guard starts.first?.0 == 0 else { throw ADBError.protocolFailure("Missing AVC start code") }
    return try starts.enumerated().map { position, start in
      let end = position + 1 < starts.count ? starts[position + 1].0 : bytes.count
      guard start.1 < end else { throw ADBError.protocolFailure("Empty AVC unit") }
      return Data(bytes[start.1 ..< end])
    }
  }
}
