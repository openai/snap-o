@preconcurrency import AVFoundation

@MainActor
protocol NativeRecordingWriter: AnyObject {
  var isComplete: Bool { get }
  func append(_ sample: CMSampleBuffer) throws
  func finish(at end: CMTime?) async throws
}

@MainActor
final class AVRecordingWriter: NativeRecordingWriter {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput?
  var isComplete: Bool {
    writer.status == .completed
  }

  var isReadyForMoreMediaData: Bool {
    input.isReadyForMoreMediaData
  }

  init(url: URL, format: CMVideoFormatDescription, start: CMTime, audioFormat: CMAudioFormatDescription? = nil) throws {
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    var settings: [String: Any]?
    if CMFormatDescriptionGetMediaSubType(format) == kCVPixelFormatType_32BGRA {
      let size = CMVideoFormatDescriptionGetDimensions(format)
      settings = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
      ]
    }
    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: format)
    if settings != nil { input.mediaTimeScale = 1_000_000 }
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw ADBError.protocolFailure("Unsupported recording format") }
    writer.add(input)
    if let audioFormat {
      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(DeviceAudioPacket.sampleRate),
        AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
      ], sourceFormatHint: audioFormat)
      audio.expectsMediaDataInRealTime = true
      guard writer.canAdd(audio) else { throw ADBError.protocolFailure("Unsupported recording audio format") }
      writer.add(audio)
      audioInput = audio
    } else { audioInput = nil }
    writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    guard writer.startWriting() else { throw writer.error ?? ADBError.protocolFailure("Could not start recording") }
    writer.startSession(atSourceTime: start)
  }

  func append(_ sample: CMSampleBuffer) throws {
    let track: AVAssetWriterInput
    if let format = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio {
      guard let audioInput else { throw ADBError.protocolFailure("Recording has no audio track") }
      track = audioInput
    } else { track = input }
    guard track.isReadyForMoreMediaData else { throw ADBError.protocolFailure("Recording storage could not keep up with the device") }
    guard track.append(sample) else { throw writer.error ?? ADBError.protocolFailure("Could not write recording sample") }
  }

  func finish(at end: CMTime?) async throws {
    if let end {
      if input.outputSettings == nil {
        // An idle Android screen may send its last encoded frame well before the audio ends.
        let marker = try CMSampleBuffer(
          dataBuffer: nil, formatDescription: input.sourceFormatHint, numSamples: 0,
          sampleTimings: [CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: end)], sampleSizes: []
        )
        CMSetAttachment(
          marker,
          key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
          value: kCFBooleanTrue,
          attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        guard input.append(marker) else { throw writer.error ?? ADBError.protocolFailure("Could not finalize the last video frame") }
      }
      writer.endSession(atSourceTime: end)
    }
    input.markAsFinished()
    audioInput?.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? ADBError.protocolFailure("Could not finalize recording") }
  }
}
