import Accelerate
@preconcurrency import AVFoundation
import Foundation

/// Gives one renderer bounded storage without holding the shared emulator's buffers.
@MainActor
final class LivePreviewFrameBuffer {
  private var pool: CVPixelBufferPool?
  private var size: CGSize = .zero

  func copyForDisplay(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
    // Compressed physical-device samples are decoded by AVSampleBufferVideoRenderer.
    guard let source = CMSampleBufferGetImageBuffer(sample) else { return sample }
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
          let format = CMSampleBufferGetFormatDescription(sample),
          let destination = buffer(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)),
          copyPixels(from: source, to: destination) else { return nil }

    var timing = CMSampleTimingInfo()
    guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
    var copied: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: destination, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &copied
    ) == noErr, let copied else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(copied, createIfNecessary: true) {
      let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return copied
  }

  private func buffer(width: Int, height: Int) -> CVPixelBuffer? {
    let dimensions = CGSize(width: width, height: height)
    if pool == nil || size != dimensions {
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
      ]
      var newPool: CVPixelBufferPool?
      guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool) == kCVReturnSuccess else { return nil }
      pool = newPool
      size = dimensions
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &buffer) == kCVReturnSuccess else {
      return nil
    }
    return buffer
  }

  private func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    guard let input = CVPixelBufferGetBaseAddress(source),
          let output = CVPixelBufferGetBaseAddress(destination) else { return false }
    var inputBuffer = vImage_Buffer(
      data: input, height: vImagePixelCount(CVPixelBufferGetHeight(source)),
      width: vImagePixelCount(CVPixelBufferGetWidth(source)), rowBytes: CVPixelBufferGetBytesPerRow(source)
    )
    var outputBuffer = vImage_Buffer(
      data: output, height: inputBuffer.height, width: inputBuffer.width,
      rowBytes: CVPixelBufferGetBytesPerRow(destination)
    )
    return vImageCopyBuffer(&inputBuffer, &outputBuffer, 4, vImage_Flags(kvImageNoFlags)) == kvImageNoError
  }
}
