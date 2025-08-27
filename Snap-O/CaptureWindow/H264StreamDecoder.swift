@preconcurrency import AVFoundation
import VideoToolbox

final class H264StreamDecoder {
  private let onSample: (CMSampleBuffer) -> Void
  private let onFormat: (CMVideoFormatDescription) -> Void

  private var buffer = Data()
  private var sps: Data?
  private var pps: Data?
  private var formatDescription: CMVideoFormatDescription?
  private var frameIndex: Int64 = 0
  private let timescale: Int32

  init(frameRate: Int32 = 30, onSampleBuffer: @escaping (CMSampleBuffer) -> Void, formatHandler: @escaping (CMVideoFormatDescription) -> Void) {
    onSample = onSampleBuffer
    onFormat = formatHandler
    timescale = frameRate
  }

  func append(_ data: Data) {
    buffer.append(data)
    parseBuffer()
  }

  // MARK: - Parsing

  private func parseBuffer() {
    let startCode = Data([0, 0, 0, 1])

    while true {
      guard let startRange = buffer.range(of: startCode) else {
        // keep only last few bytes in case a start code spans across chunks
        if buffer.count > 3 {
          buffer = Data(buffer.suffix(3))
        }
        return
      }
      if startRange.lowerBound > 0 {
        buffer.removeSubrange(0 ..< startRange.lowerBound)
      }

      guard let nextRange = buffer.range(of: startCode, options: [], in: startRange.upperBound ..< buffer.endIndex) else {
        // incomplete NAL, wait for more data
        return
      }

      let nalData = buffer[startRange.upperBound ..< nextRange.lowerBound]
      handleNAL(Data(nalData))
      buffer.removeSubrange(0 ..< nextRange.lowerBound)
    }
  }

  private func handleNAL(_ nal: Data) {
    guard let firstByte = nal.first else { return }
    let type = firstByte & 0x1F

    switch type {
    case 7:
      sps = nal
      _ = makeFormatDescriptionIfPossible()
    case 8:
      pps = nal
      _ = makeFormatDescriptionIfPossible()
    case 5, 1:
      guard makeFormatDescriptionIfPossible(), let formatDescription else { return }
      var nalUnits: [Data] = []
      if type == 5 { // IDR, prepend SPS/PPS
        if let sps { nalUnits.append(sps) }
        if let pps { nalUnits.append(pps) }
      }
      nalUnits.append(nal)
      if let sample = makeSampleBuffer(from: nalUnits, format: formatDescription, isIDR: type == 5) {
        onSample(sample)
      }
    default:
      break
    }
  }

  private func makeFormatDescriptionIfPossible() -> Bool {
    if formatDescription != nil { return true }
    guard let sps, let pps else { return false }
    var formatDesc: CMFormatDescription?
    let result = sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: 2,
          parameterSetPointers: [
            spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
            ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
          ],
          parameterSetSizes: [sps.count, pps.count],
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &formatDesc
        )
      }
    }
    if result == noErr, let desc = formatDesc {
      formatDescription = desc
      onFormat(desc)
      return true
    }
    return false
  }

  private func makeSampleBuffer(from nalUnits: [Data], format: CMVideoFormatDescription, isIDR: Bool) -> CMSampleBuffer? {
    var data = Data()
    for unit in nalUnits {
      var length = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: &length) { bytes in
        data.append(contentsOf: bytes)
      }
      data.append(unit)
    }

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

    data.withUnsafeBytes { ptr in
      _ = CMBlockBufferReplaceDataBytes(
        with: ptr.baseAddress!,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: timescale),
      presentationTimeStamp: CMTime(value: frameIndex, timescale: timescale),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = data.count
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: format,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else { return nil }

    if isIDR,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
    {
      let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
    }

    frameIndex += 1
    return sampleBuffer
  }
}
