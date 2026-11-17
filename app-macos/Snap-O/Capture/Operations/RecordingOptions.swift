struct RecordingOptions {
  let recordsBugReport: Bool
  let showsTouches: Bool
  var audioMode: RecordingAudioMode = .off

  enum VideoSource {
    case screenrecord, androidHelper, sharedPreview
  }

  func videoSource(isLocalEmulator: Bool) -> VideoSource {
    if recordsBugReport { return .screenrecord }
    if isLocalEmulator { return audioMode == .off ? .screenrecord : .androidHelper }
    return .sharedPreview
  }
}

enum RecordingAudioMode {
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
