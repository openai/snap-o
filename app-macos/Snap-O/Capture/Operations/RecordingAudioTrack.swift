@preconcurrency import AVFoundation

struct RecordingAudioError: LocalizedError {
  let errorDescription: String?
}

@MainActor
final class RecordingAudioTrack {
  private struct Output {
    let writer: any NativeRecordingWriter
    let start: CMTime
    let hostTime: CMTime
  }

  let format: CMAudioFormatDescription
  private var pending: [DeviceAudioPacket] = []
  private var output: Output?
  private let mixesComputerMicrophone: Bool
  private var mixer: RecordingAudioMixer?
  private var microphoneSilenced = false
  private(set) var captureWarning: String?
  private(set) var endTime: CMTime?

  init(mixesComputerMicrophone: Bool = false) throws {
    self.mixesComputerMicrophone = mixesComputerMicrophone
    format = try DeviceAudioPacket.makeFormat()
  }

  var hasBufferedSamples: Bool {
    !pending.isEmpty
  }

  func receive(_ event: DeviceAudioPacket.Event) throws {
    switch event {
    case .samples(let packet):
      if output != nil {
        try write(packet, from: .device)
      } else {
        guard pending.count < 512 else { throw ADBError.protocolFailure("Recording waited too long for its first video frame") }
        pending.append(packet)
      }
    case .microphoneSilenced(let silenced):
      microphoneSilenced = silenced
      if output != nil { updateMicrophoneWarning() }
    }
  }

  func start(at start: CMTime, hostTime: CMTime, writer: any NativeRecordingWriter) {
    output = Output(writer: writer, start: start, hostTime: hostTime)
    if mixesComputerMicrophone { mixer = RecordingAudioMixer(start: start) }
    updateMicrophoneWarning()
  }

  func receiveComputerMicrophone(_ packet: DeviceAudioPacket, until stop: CMTime?) throws {
    guard let output else { return }
    // The first fresh video keyframe ties the host clock to the Android video clock.
    let timestamp = output.start + (packet.timestamp - output.hostTime)
    var pcm = packet.pcm
    if let stop {
      let frames = CMTimeConvertScale(stop - packet.timestamp, timescale: DeviceAudioPacket.sampleRate, method: .roundTowardZero).value
      guard frames > 0 else { return }
      if frames < pcm.count / DeviceAudioPacket.bytesPerFrame { pcm = pcm.prefix(Int(frames) * DeviceAudioPacket.bytesPerFrame) }
    }
    let duration = CMTime(value: Int64(pcm.count / DeviceAudioPacket.bytesPerFrame), timescale: DeviceAudioPacket.sampleRate)
    guard timestamp + duration > output.start else { return }
    try write(DeviceAudioPacket(timestamp: timestamp, pcm: pcm), from: .computer)
  }

  func appendBufferedSamples() throws {
    let buffered = pending
    pending.removeAll()
    for packet in buffered {
      try write(packet, from: .device)
    }
  }

  func finish() throws {
    try mixer?.finish(write: append)
  }

  private func updateMicrophoneWarning() {
    if microphoneSilenced { captureWarning = "Android silenced the device microphone during this recording." }
  }

  private func write(_ packet: DeviceAudioPacket, from source: RecordingAudioMixer.Source) throws {
    if let mixer { try mixer.receive(packet, from: source, write: append) } else { try append(packet) }
  }

  private func append(_ packet: DeviceAudioPacket) throws {
    guard let output, let sample = try packet.sample(format: format, startingAt: output.start) else { return }
    try output.writer.append(sample)
    endTime = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
  }
}
