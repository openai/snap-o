import SwiftUI

struct CaptureReviewVideo: View {
  let url: URL
  let mediaFrame: CGRect
  let controlsFrame: CGRect
  let playback: CaptureReviewPlayback
  let trim: CaptureTrimRange?
  let onTrimValidityChange: (Bool) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      CaptureVideoPlayer(
        player: playback.player,
        showsPlaybackControls: false,
        togglePlayback: { playback.togglePlayback() },
        stepFrame: { playback.stepFrame($0) },
        playbackControlsFrame: playback.isTrimming ? nil : controlsFrame.offsetBy(dx: -mediaFrame.minX, dy: -mediaFrame.minY)
      )
      .frame(width: mediaFrame.width, height: mediaFrame.height)
      .clipped()
      .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
      .position(x: mediaFrame.midX, y: mediaFrame.midY)

      Group {
        if playback.isTrimming {
          CaptureTrimControls(playback: playback, url: url, onValidityChange: onTrimValidityChange)
        } else {
          CapturePlaybackControls(playback: playback)
        }
      }
      .frame(width: controlsFrame.width, height: controlsFrame.height)
      .position(x: controlsFrame.midX, y: controlsFrame.midY)
    }
    .background {
      WindowVisibilityReader { playback.setWindowVisible($0) }
        .frame(width: 0, height: 0)
    }
    .task(id: url) { await playback.load(url, trim: trim) }
    .onAppear { markPerfMilestones() }
    .onDisappear { playback.stop() }
  }
}

private struct CapturePlaybackControls: View {
  let playback: CaptureReviewPlayback

  var body: some View {
    HStack(spacing: 8) {
      Button { playback.togglePlayback() } label: {
        Image(systemName: playback.wantsPlayback ? "pause.fill" : "play.fill")
          .frame(width: 16, height: 24)
      }
      .help(playback.wantsPlayback ? "Pause (Space)" : "Play (Space)")
      .accessibilityLabel(playback.wantsPlayback ? "Pause" : "Play")

      Text(CaptureReviewPlayback.timestamp(playback.elapsedTime))
        .fixedSize()
        .accessibilityLabel("Elapsed time")
      Slider(
        value: Binding(get: { playback.elapsedTime }, set: { playback.seek(to: playback.playbackRange.start + $0) }),
        in: 0 ... max(playback.playbackRange.duration, 0.01)
      ) { playback.setScrubbing($0) }
        .controlSize(.mini)
        .tint(.primary)
        .accessibilityLabel("Playback position")
        .accessibilityValue(CaptureReviewPlayback.timestamp(playback.elapsedTime))
      Text(CaptureReviewPlayback.timestamp(playback.playbackRange.duration))
        .fixedSize()
        .accessibilityLabel("Duration")

      Menu {
        ForEach([Float(0.25), 0.5, 1, 1.5, 2], id: \.self) { speed in
          Button { playback.setSpeed(speed) } label: {
            if playback.speed == speed {
              Label("\(speed.formatted())×", systemImage: "checkmark")
            } else {
              Text("\(speed.formatted())×")
            }
          }
        }
      } label: {
        Text("\(playback.speed.formatted())×")
          .font(.system(size: 11, weight: .medium).monospacedDigit())
          .frame(minWidth: 22)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Playback speed")
      .accessibilityLabel("Playback speed")
    }
    .font(.system(size: 11, weight: .medium).monospacedDigit())
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .frame(maxHeight: .infinity)
    .background(.primary.opacity(0.08), in: Capsule())
    .disabled(playback.duration <= 0)
    .help(playback.errorMessage ?? "Space to play or pause. Left and Right Arrow to step one frame.")
    .focusable()
    .onKeyPress(.space) { playback.togglePlayback()
      return .handled
    }
    .onKeyPress(.leftArrow) { playback.stepFrame(-1)
      return .handled
    }
    .onKeyPress(.rightArrow) { playback.stepFrame(1)
      return .handled
    }
  }
}
