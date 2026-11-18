@preconcurrency import AVFoundation

struct RecordingAudioError: LocalizedError {
  let errorDescription: String?
}

@MainActor
final class RecordingAudioTrack {
  let format: CMAudioFormatDescription
  private var pending: [(packet: DeviceAudioPacket, source: RecordingAudioMixer.Source)] = []
  private var output: (writer: any NativeRecordingWriter, start: CMTime)?
  private let mixesComputerMicrophone: Bool
  private var mixer: RecordingAudioMixer?
  private var microphoneSilenced = false
  private(set) var captureWarning: String?
  private(set) var endTime: CMTime?

  init(mixesComputerMicrophone: Bool = false) throws {
    self.mixesComputerMicrophone = mixesComputerMicrophone
    format = try DeviceAudioPacket.makeFormat()
  }

  var hasBufferedDeviceSamples: Bool {
    pending.contains { $0.source == .device }
  }

  func receive(_ event: DeviceAudioPacket.Event) throws {
    switch event {
    case .samples(let packet):
      try write(packet, from: .device)
    case .microphoneSilenced(let silenced):
      microphoneSilenced = silenced
      if output != nil { updateMicrophoneWarning() }
    }
  }

  func start(at start: CMTime, writer: any NativeRecordingWriter) {
    output = (writer, start)
    if mixesComputerMicrophone { mixer = RecordingAudioMixer(start: start) }
    updateMicrophoneWarning()
  }

  func receiveComputerMicrophone(_ packet: DeviceAudioPacket, deviceClockOffset: CMTime, until stop: CMTime?) throws {
    var pcm = packet.pcm
    if let stop {
      let frames = CMTimeConvertScale(stop - packet.timestamp, timescale: DeviceAudioPacket.sampleRate, method: .roundTowardZero).value
      guard frames > 0 else { return }
      if frames < pcm.count / DeviceAudioPacket.bytesPerFrame { pcm = pcm.prefix(Int(frames) * DeviceAudioPacket.bytesPerFrame) }
    }
    try write(DeviceAudioPacket(timestamp: packet.timestamp + deviceClockOffset, pcm: pcm), from: .computer)
  }

  func appendBufferedSamples() throws {
    let buffered = pending
    pending.removeAll()
    for (packet, source) in buffered {
      try write(packet, from: source)
    }
  }

  func finish() throws {
    try mixer?.finish(write: append)
  }

  private func updateMicrophoneWarning() {
    if microphoneSilenced { captureWarning = "Android silenced the device microphone during this recording." }
  }

  private func write(_ packet: DeviceAudioPacket, from source: RecordingAudioMixer.Source) throws {
    guard output != nil else {
      guard pending.count < (mixesComputerMicrophone ? 1024 : 512) else {
        throw ADBError.protocolFailure("Recording waited too long for its first video frame")
      }
      pending.append((packet, source))
      return
    }
    if let mixer { try mixer.receive(packet, from: source, write: append) } else { try append(packet) }
  }

  private func append(_ packet: DeviceAudioPacket) throws {
    guard let output, let sample = try packet.sample(format: format, startingAt: output.start) else { return }
    try output.writer.append(sample)
    endTime = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
  }
}
