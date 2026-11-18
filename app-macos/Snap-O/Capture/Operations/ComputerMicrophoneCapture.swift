@preconcurrency import AVFoundation

/// The capture session and its delegate run on the same serial queue.
final class ComputerMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "Snap-O.ComputerMicrophone")
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private var observers: [NSObjectProtocol] = []
  private let stream = AsyncThrowingStream<DeviceAudioPacket, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))

  var packets: AsyncThrowingStream<DeviceAudioPacket, Error> {
    stream.stream
  }

  func start() async throws {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    var allowed = status == .authorized
    if status == .notDetermined {
      // Closing the recording can cancel the wait while the system prompt is open.
      let (responses, response) = AsyncStream<Bool>.makeStream()
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        response.yield(granted)
        response.finish()
      }
      var iterator = responses.makeAsyncIterator()
      allowed = await iterator.next() == true
    }
    try Task.checkCancellation()
    guard allowed else {
      throw RecordingAudioError(
        errorDescription: "Allow Snap-O to use the microphone in System Settings → Privacy & Security → Microphone."
      )
    }
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
      queue.async { ready.resume(with: Result { try self.startSession() }) }
    }
  }

  private func startSession() throws {
    guard let device = AVCaptureDevice.default(for: .audio) else {
      throw RecordingAudioError(errorDescription: "No computer microphone is available.")
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw RecordingAudioError(errorDescription: "Could not open the computer microphone.") }
    session.addInput(input)
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(DeviceAudioPacket.sampleRate), AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
    ]
    guard session.canAddOutput(output) else { throw RecordingAudioError(errorDescription: "Could not capture computer microphone audio.") }
    session.addOutput(output)
    output.setSampleBufferDelegate(self, queue: queue)
    let ended = RecordingAudioError(errorDescription: "The computer microphone stopped delivering audio.")
    for (name, object) in [
      (AVCaptureSession.runtimeErrorNotification, session as NSObject),
      (AVCaptureSession.wasInterruptedNotification, session),
      (AVCaptureSession.didStopRunningNotification, session),
      (AVCaptureDevice.wasDisconnectedNotification, device)
    ] {
      let continuation = stream.continuation
      let observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { note in
        continuation.finish(throwing: note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? ended)
      }
      observers.append(observer)
    }
    session.startRunning()
    guard session.isRunning else { throw RecordingAudioError(errorDescription: "Could not start the computer microphone.") }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    do {
      guard let clock = session.synchronizationClock
      else { throw RecordingAudioError(errorDescription: "The computer microphone clock is unavailable.") }
      let hostTime = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
      let packet = try Self.packet(from: sampleBuffer, hostTime: hostTime)
      if case .dropped = stream.continuation.yield(packet) {
        throw RecordingAudioError(errorDescription: "Recording could not keep up with the computer microphone.")
      }
    } catch {
      stream.continuation.finish(throwing: error)
    }
  }

  static func packet(from sample: CMSampleBuffer, hostTime: CMTime) throws -> DeviceAudioPacket {
    let count = sample.numSamples * DeviceAudioPacket.bytesPerFrame
    guard hostTime.isNumeric, count > 0, let block = sample.dataBuffer, CMBlockBufferGetDataLength(block) == count,
          let format = sample.formatDescription?.audioStreamBasicDescription,
          format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == Double(DeviceAudioPacket.sampleRate),
          format.mChannelsPerFrame == 2, format.mBitsPerChannel == 16,
          format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
          format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    else { throw RecordingAudioError(errorDescription: "The computer microphone returned an unsupported audio format.") }
    var pcm = Data(count: count)
    let status = pcm.withUnsafeMutableBytes { bytes in
      guard let address = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
      return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: address)
    }
    guard status == noErr else { throw RecordingAudioError(errorDescription: "Could not read the computer microphone samples.") }
    return DeviceAudioPacket(timestamp: hostTime, pcm: pcm)
  }

  func stop() async {
    await withCheckedContinuation { stopped in
      queue.async {
        self.observers.forEach(NotificationCenter.default.removeObserver)
        self.observers.removeAll()
        self.output.setSampleBufferDelegate(nil, queue: nil)
        if self.session.isRunning { self.session.stopRunning() }
        self.stream.continuation.finish()
        stopped.resume()
      }
    }
  }
}
