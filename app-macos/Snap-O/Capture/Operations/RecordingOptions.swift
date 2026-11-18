struct RecordingOptions {
  let recordsBugReport: Bool
  let showsTouches: Bool
  var audio = RecordingAudioSources()

  enum VideoSource {
    case screenrecord, androidHelper, sharedPreview
  }

  func videoSource(isLocalEmulator: Bool) -> VideoSource {
    if recordsBugReport { return .screenrecord }
    if isLocalEmulator { return audio == RecordingAudioSources() ? .screenrecord : .androidHelper }
    return .sharedPreview
  }
}

enum RecordingMicrophone: String {
  case off, device, computer
}

struct RecordingAudioSources: Equatable {
  var playback = false
  var microphone: RecordingMicrophone = .off

  var deviceMode: DeviceAudioMode {
    DeviceAudioMode(playback: playback, microphone: microphone == .device)
  }

  func available(supportsDeviceAudio: Bool) -> Self {
    supportsDeviceAudio ? self : Self(microphone: microphone == .computer ? .computer : .off)
  }
}

enum DeviceAudioMode {
  case off, playback, microphone, both

  init(playback: Bool, microphone: Bool) {
    switch (playback, microphone) {
    case (false, false): self = .off
    case (true, false): self = .playback
    case (false, true): self = .microphone
    case (true, true): self = .both
    }
  }
}
