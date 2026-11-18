import SwiftUI

extension RecordingAudioSources {
  var accessibilityValue: String {
    switch (playback, microphone) {
    case (false, .off): "Audio off"
    case (true, .off): "Device audio on"
    case (false, .device): "Device microphone on"
    case (true, .device): "Device audio and device microphone on"
    case (false, .computer): "Computer microphone on"
    case (true, .computer): "Device audio and computer microphone on"
    }
  }
}

struct RecordingAudioIcon: View {
  let sources: RecordingAudioSources

  var body: some View {
    symbol
      .font(.system(size: 16, weight: .medium))
      .symbolRenderingMode(.monochrome)
      .captureActionIconFrame()
  }

  @ViewBuilder private var symbol: some View {
    switch (sources.playback, sources.microphone) {
    case (false, .off):
      Image(systemName: "speaker.slash")
        .font(SnapOToolbarStyle.iconFont)
    case (true, .off):
      Image(systemName: "speaker.wave.2.fill")
    case (false, _):
      Image(systemName: "microphone.fill")
    case (true, _):
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
