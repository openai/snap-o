import SwiftUI

struct CaptureReviewVideo: View {
  let url: URL
  let mediaFrame: CGRect
  let controlsFrame: CGRect
  let playback: CaptureReviewPlayback
  let trim: CaptureTrimRange?
  var load: (@MainActor () async -> Void)?
  let onTrimValidityChange: (Bool) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      CaptureVideoPlayer(
        player: playback.player,
        showsPlaybackControls: false,
        // Live Text analysis can steal focus from time fields after each seek.
        allowsVideoFrameAnalysis: !playback.isTrimming,
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
    .task(id: url) {
      if let load { await load() } else { await playback.load(url, trim: trim) }
    }
    .onAppear { markPerfMilestones() }
    .onDisappear { if load == nil { playback.stop() } }
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

      CapturePlaybackVolumeControl.buttonAnchor

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

struct CapturePlaybackVolumeControl: View {
  let playback: CaptureReviewPlayback
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isHovering = false
  @State private var isDragging = false

  struct ButtonBounds: PreferenceKey {
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
      value = nextValue() ?? value
    }
  }

  static var buttonAnchor: some View {
    Color.clear
      .frame(width: 24, height: 24)
      .anchorPreference(key: ButtonBounds.self, value: .bounds) { $0 }
      .accessibilityHidden(true)
  }

  private var muteLabel: String {
    guard playback.hasAudioTrack else { return "No audio track" }
    return playback.volume == 0 ? "Unmute" : "Mute"
  }

  var body: some View {
    let showsSlider = playback.hasAudioTrack && (isHovering || isDragging)
    VStack(spacing: -1) {
      if showsSlider {
        VerticalVolumeSlider(playback: playback, isDragging: $isDragging)
          .frame(width: 16, height: 90)
          .padding(6)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
          .transition(.offset(y: reduceMotion ? 0 : 4).combined(with: .opacity))
      }

      Button(action: playback.toggleMute) {
        Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: Double(playback.volume))
          .font(.system(size: 12, weight: .medium))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(muteLabel)
      .accessibilityValue(playback.volume.formatted(.percent))
      .accessibilityAdjustableAction { direction in
        playback.setVolume(playback.volume + (direction == .increment ? 0.05 : -0.05))
      }
      .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        playback.setVolume(playback.volume + (press.key == .upArrow ? 0.05 : -0.05))
        return .handled
      }
    }
    .fixedSize()
    .animation(showsSlider ? .easeOut(duration: 0.125) : .easeIn(duration: 0.225), value: showsSlider)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .disabled(!playback.hasAudioTrack)
  }
}

private struct VerticalVolumeSlider: NSViewRepresentable {
  let playback: CaptureReviewPlayback
  @Binding var isDragging: Bool

  func makeNSView(context: Context) -> Slider {
    let slider = Slider()
    slider.cell = RoundThumbCell()
    slider.minValue = 0
    slider.maxValue = 1
    slider.isVertical = true
    slider.isContinuous = true
    slider.controlSize = .small
    slider.target = slider
    slider.action = #selector(Slider.volumeChanged)
    slider.setAccessibilityLabel("Volume")
    return slider
  }

  func updateNSView(_ slider: Slider, context: Context) {
    if slider.floatValue != playback.volume { slider.floatValue = playback.volume }
    slider.setAccessibilityValueDescription(playback.volume.formatted(.percent))
    slider.setVolume = playback.setVolume
    slider.setDragging = { isDragging = $0 }
  }

  private final class RoundThumbCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
      // Inset the painted track while keeping AppKit's full range for dragging.
      let inset = (trackRect.width - rect.width) / 2
      super.drawBar(inside: rect.insetBy(dx: 0, dy: inset), flipped: flipped)
    }

    override func knobRect(flipped: Bool) -> NSRect {
      let bar = barRect(flipped: flipped)
      let diameter = trackRect.width
      let progress = flipped ? 1 - doubleValue : doubleValue
      let y = bar.minY + (bar.height - diameter) * progress
      return NSRect(x: bar.midX - diameter / 2, y: y, width: diameter, height: diameter)
    }

    override func drawKnob(_ knobRect: NSRect) {
      let circle = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
      NSColor.white.setFill()
      circle.fill()
      NSColor.black.withAlphaComponent(0.15).setStroke()
      circle.lineWidth = 0.5
      circle.stroke()
    }
  }

  final class Slider: NSSlider {
    var setVolume: (Float) -> Void = { _ in }
    var setDragging: (Bool) -> Void = { _ in }

    @objc
    func volumeChanged() {
      setVolume(floatValue)
    }

    override func mouseDown(with event: NSEvent) {
      setDragging(true)
      super.mouseDown(with: event)
      setDragging(false)
    }
  }
}
