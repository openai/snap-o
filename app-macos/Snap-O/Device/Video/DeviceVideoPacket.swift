@preconcurrency import AVFoundation
import Foundation
import zlib

/// The helper sends complete AVC access units or compressed RGBA frames with device timestamps.
enum DeviceVideoPacket {
  case display(width: Int, height: Int, density: Int, rotation: Int)
  case frame(flags: UInt32, timestamp: Int64, data: Data)
  case rgba(width: Int, height: Int, timestamp: Int64, pixels: Data)
  case failure(DeviceVideoFailure)

  static let magic: UInt32 = 0x534E_5631

  static func validateHeader(_ data: Data) throws {
    guard data.count == 4, data.reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) == magic else {
      throw ADBError.protocolFailure("Unsupported device video protocol")
    }
  }

  static let maximumBytes = 16 * 1024 * 1024

  static func read(from readBytes: (Int) throws -> Data) throws -> Self {
    func number(_ count: Int) throws -> UInt64 {
      let bytes = try readBytes(count)
      guard bytes.count == count else { throw ADBError.protocolFailure("Truncated video packet") }
      return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
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
    case 3:
      let stage = try UInt8(number(1))
      let retryable = try number(1)
      let code = try UInt32(number(4))
      guard let stage = DeviceVideoFailure.Stage(rawValue: stage), retryable <= 1 else {
        throw ADBError.protocolFailure("Invalid video failure packet")
      }
      return .failure(DeviceVideoFailure(stage: stage, retryable: retryable == 1, codecError: Int32(bitPattern: code)))
    case 4:
      let width = try Int(number(4))
      let height = try Int(number(4))
      let timestamp = try number(8)
      let count = try Int(number(4))
      guard (2 ... 8192).contains(width), (2 ... 8192).contains(height),
            width * height * 4 <= maximumBytes, timestamp <= Int64.max,
            count > 0, count <= maximumBytes else {
        throw ADBError.protocolFailure("Invalid RGBA video packet")
      }
      let compressed = try readBytes(count)
      guard compressed.count == count else { throw ADBError.protocolFailure("Truncated RGBA video packet") }
      let pixels = try inflateRGBA(compressed, byteCount: width * height * 4)
      return .rgba(width: width, height: height, timestamp: Int64(timestamp), pixels: pixels)
    default:
      throw ADBError.protocolFailure("Unknown video packet")
    }
  }

  private static func inflateRGBA(_ data: Data, byteCount: Int) throws -> Data {
    var pixels = Data(count: byteCount)
    var outputCount = uLongf(byteCount)
    var inputCount = uLong(data.count)
    let status = pixels.withUnsafeMutableBytes { output in
      data.withUnsafeBytes { input in
        uncompress2(
          output.baseAddress?.assumingMemoryBound(to: Bytef.self), &outputCount,
          input.baseAddress?.assumingMemoryBound(to: Bytef.self), &inputCount
        )
      }
    }
    guard status == Z_OK, outputCount == byteCount, inputCount == data.count else {
      throw ADBError.protocolFailure("Invalid compressed RGBA frame")
    }
    return pixels
  }
}

/// Fixed protocol fields keep framework messages and display metadata off the wire.
struct DeviceVideoFailure: LocalizedError, Equatable {
  enum Stage: UInt8, CaseIterable {
    case setup = 1, display, encoder, capabilities, configuration, inputSurface, mirror, start, stream, capture

    var action: String {
      switch self {
      case .setup: "start the device helper"
      case .display: "read the device display"
      case .encoder: "open an H.264 encoder"
      case .capabilities: "find a supported video configuration"
      case .configuration: "configure the video encoder"
      case .inputSurface: "create the encoder input surface"
      case .mirror: "mirror the device display"
      case .start: "start the video encoder"
      case .stream: "encode the device display"
      case .capture: "capture the device display"
      }
    }
  }

  let stage: Stage
  let retryable: Bool
  /// Zero means that Android did not provide a codec error code.
  let codecError: Int32

  var errorDescription: String? {
    var message = "Could not \(stage.action) on this device."
    if codecError != 0 { message += " Codec error: \(codecError)." }
    return message
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
