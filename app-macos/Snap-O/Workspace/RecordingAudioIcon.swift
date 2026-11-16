import SwiftUI

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

  var accessibilityValue: String {
    switch self {
    case .off: "Audio off"
    case .playback: "Device audio on"
    case .microphone: "Device microphone on"
    case .both: "Device audio and microphone on"
    }
  }
}

struct RecordingAudioIcon: View {
  let mode: RecordingAudioMode

  var body: some View {
    symbol
      .font(.system(size: 16, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .captureActionIconFrame()
  }

  @ViewBuilder private var symbol: some View {
    switch mode {
    case .off:
      Image(systemName: "speaker.slash")
        .font(SnapOToolbarStyle.iconFont)
    case .playback:
      Image(systemName: "speaker.wave.2.fill")
    case .microphone:
      Image(systemName: "microphone.fill")
    case .both:
      ZStack {
        Image(systemName: "speaker.wave.1.fill")
          .offset(x: -4, y: -3.5)
        Image(systemName: "microphone.fill")
          .offset(x: 4, y: 3.5)
      }
      .font(.system(size: 11, weight: .medium))
    }
  }
}
