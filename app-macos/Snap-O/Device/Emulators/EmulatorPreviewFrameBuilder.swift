import Accelerate
@preconcurrency import AVFoundation
import Foundation

struct EmulatorPreviewError: LocalizedError {
  let message: String
  var errorDescription: String? {
    message
  }
}

/// Used by one stream task. Every delivered sample retains its own pool buffer.
final class EmulatorPreviewFrameBuilder {
  private var pool: CVPixelBufferPool?
  private var size: CGSize = .zero

  func makeSample(rgba: Data, width: Int, height: Int, timestamp: UInt64) throws -> CMSampleBuffer? {
    guard width > 0, height > 0, width <= 8192, height <= 8192,
          width * height <= 16 * 1024 * 1024,
          rgba.count == width * height * 4,
          timestamp <= UInt64(Int64.max) else {
      throw EmulatorPreviewError(message: "The emulator returned an invalid preview frame.")
    }
    let newSize = CGSize(width: width, height: height)
    if pool == nil || size != newSize {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
      ]
      var newPool: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool) == kCVReturnSuccess else {
        throw EmulatorPreviewError(message: "Could not allocate emulator preview buffers.")
      }
      pool = newPool
      size = newSize
    }
    guard let pool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
    let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixelBuffer)
    // Drop frames instead of growing memory when the renderer falls behind.
    if allocation == kCVReturnWouldExceedAllocationThreshold { return nil }
    guard allocation == kCVReturnSuccess, let pixelBuffer else {
      throw EmulatorPreviewError(message: "Could not allocate an emulator preview frame.")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let conversion: vImage_Error = rgba.withUnsafeBytes { bytes in
      guard let sourceAddress = bytes.baseAddress,
            let destinationAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        return vImage_Error(kvImageNullPointerArgument)
      }
      var source = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: sourceAddress),
        height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4
      )
      var destination = vImage_Buffer(
        data: destinationAddress,
        height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
      )
      return vImagePermuteChannels_ARGB8888(&source, &destination, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard conversion == kvImageNoError else {
      throw EmulatorPreviewError(message: "Could not convert the emulator preview frame.")
    }

    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
    ) == noErr, let format else {
      throw EmulatorPreviewError(message: "Could not describe the emulator preview frame.")
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 1_000_000),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample
    ) == noErr, let sample else {
      throw EmulatorPreviewError(message: "Could not prepare the emulator preview frame.")
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        attachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sample
  }
}
