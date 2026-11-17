@preconcurrency import AVFoundation

@MainActor
final class RecordingAudioTrack {
  let format: CMAudioFormatDescription
  private var pending: [DeviceAudioPacket] = []
  private var output: (writer: any NativeRecordingWriter, start: CMTime)?
  private var microphoneSilenced = false
  private(set) var captureWarning: String?
  private(set) var endTime: CMTime?

  init() throws {
    format = try DeviceAudioPacket.makeFormat()
  }

  var hasBufferedSamples: Bool {
    !pending.isEmpty
  }

  func receive(_ event: DeviceAudioPacket.Event) throws {
    switch event {
    case .samples(let packet):
      if let output {
        try append(packet, to: output.writer, startingAt: output.start)
      } else {
        guard pending.count < 512 else { throw ADBError.protocolFailure("Recording waited too long for its first video frame") }
        pending.append(packet)
      }
    case .microphoneSilenced(let silenced):
      microphoneSilenced = silenced
      if output != nil { updateMicrophoneWarning() }
    }
  }

  func start(at start: CMTime, writer: any NativeRecordingWriter) {
    output = (writer, start)
    updateMicrophoneWarning()
  }

  func appendBufferedSamples() throws {
    guard let output else { return }
    let buffered = pending
    pending.removeAll()
    for packet in buffered {
      try append(packet, to: output.writer, startingAt: output.start)
    }
  }

  private func updateMicrophoneWarning() {
    if microphoneSilenced { captureWarning = "Android silenced the device microphone during this recording." }
  }

  private func append(_ packet: DeviceAudioPacket, to writer: any NativeRecordingWriter, startingAt start: CMTime) throws {
    guard let sample = try packet.sample(format: format, startingAt: start) else { return }
    try writer.append(sample)
    endTime = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
  }
}
