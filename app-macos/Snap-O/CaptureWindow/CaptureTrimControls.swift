@preconcurrency import AVFoundation
import SwiftUI

struct CaptureTrimToolbar: View {
  let canApply: Bool
  let cancel: () -> Void
  let apply: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: cancel) {
        Image(systemName: "xmark")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: SnapOToolbarStyle.singleControlSize, height: SnapOToolbarStyle.singleControlSize)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .glassEffect(.regular.interactive(), in: Circle())
      .help("Cancel Trim (Esc)")
      .accessibilityLabel("Cancel Trim")
      .keyboardShortcut(.cancelAction)

      Spacer(minLength: 0)

      Button(action: apply) {
        Image(systemName: "scissors")
          .font(SnapOToolbarStyle.iconFont)
          .frame(width: SnapOToolbarStyle.singleControlSize, height: SnapOToolbarStyle.singleControlSize)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.white)
      .glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
      .help("Apply Trim")
      .accessibilityLabel("Apply Trim")
      .disabled(!canApply)
    }
  }
}

struct CaptureTrimControls: View {
  let playback: CaptureReviewPlayback
  let url: URL
  let onValidityChange: (Bool) -> Void
  @State private var startText = ""
  @State private var endText = ""
  @FocusState private var focusedField: Boundary?

  private enum Boundary { case start, end }

  private var validStart: Double? {
    guard let value = playback.timecode.seconds(from: startText),
          value >= 0, value <= playback.trimSelection.end - 1 / playback.frameRate + 0.000001 else { return nil }
    return value
  }

  private var validEnd: Double? {
    guard let value = playback.timecode.seconds(from: endText),
          value >= playback.trimSelection.start + 1 / playback.frameRate - 0.000001,
          value <= playback.duration + 0.5 / playback.frameRate else { return nil }
    return min(value, playback.duration)
  }

  var body: some View {
    VStack(spacing: CaptureReviewLayout.trimTimeFieldSpacing) {
      HStack(spacing: 8) {
        playButton
        CaptureTrimTimeline(playback: playback, url: url)
      }
      .frame(height: CaptureReviewLayout.trimTimelineHeight)
      timeFields
    }
    .font(.system(size: 11, weight: .medium).monospacedDigit())
    .controlSize(.mini)
    .foregroundStyle(.primary)
    .onAppear { synchronizeFields() }
    .onChange(of: playback.trimSelection) { synchronizeFields() }
    .onChange(of: validStart != nil && validEnd != nil, initial: true) { _, isValid in
      onValidityChange(isValid)
    }
    .onChange(of: focusedField) { old, _ in
      if old == .start, validStart != nil { startText = playback.timecode.string(for: playback.trimSelection.start) }
      if old == .end, validEnd != nil { endText = playback.timecode.string(for: playback.trimSelection.end) }
    }
    .onExitCommand { playback.cancelTrimming() }
  }

  private var playButton: some View {
    Button { playback.togglePlayback() } label: {
      Image(systemName: playback.wantsPlayback ? "pause.fill" : "play.fill")
        .font(.system(size: 17, weight: .medium))
        .frame(width: 24, height: CaptureReviewLayout.trimTimelineHeight)
    }
    .buttonStyle(.plain)
    .help(playback.wantsPlayback ? "Pause" : "Play selection")
    .accessibilityLabel(playback.wantsPlayback ? "Pause" : "Play selection")
  }

  private var timeFields: some View {
    HStack(spacing: 8) {
      timeField("Start", text: $startText, boundary: .start, isValid: validStart != nil)
      Text("to")
        .foregroundStyle(.secondary)
        .fixedSize()
      timeField("End", text: $endText, boundary: .end, isValid: validEnd != nil)
    }
    .frame(maxWidth: .infinity)
  }

  private func timeField(_ label: String, text: Binding<String>, boundary: Boundary, isValid: Bool) -> some View {
    TextField(label, text: Binding(
      get: { text.wrappedValue },
      set: {
        text.wrappedValue = $0
        switch boundary {
        case .start:
          if let value = validStart { playback.setTrimStart(value) }
        case .end:
          if let value = validEnd { playback.setTrimEnd(value) }
        }
      }
    ))
    .textFieldStyle(.roundedBorder)
    .multilineTextAlignment(.center)
    .frame(width: 76, height: CaptureReviewLayout.trimTimeFieldHeight)
    .focused($focusedField, equals: boundary)
    .foregroundStyle(isValid ? Color.primary : Color.red)
    .accessibilityLabel("Trim \(label.lowercased()) time")
    .help(
      "\(label): minutes:seconds:frames (\(playback.frameRate.formatted(.number.precision(.fractionLength(0 ... 2)))) fps)."
        + " Up/Down to step one frame."
    )
    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
      guard focusedField == boundary, press.modifiers.isDisjoint(with: [.command, .control, .option, .shift]) else { return .ignored }
      stepTimeField(boundary, direction: press.key == .upArrow ? 1 : -1)
      return .handled
    }
    .onSubmit { focusedField = nil }
  }

  private func stepTimeField(_ boundary: Boundary, direction: Int) {
    let delta = Double(direction) / playback.frameRate
    switch boundary {
    case .start:
      guard let value = validStart else { return }
      playback.setTrimStart(value + delta)
      startText = playback.timecode.string(for: playback.trimSelection.start)
    case .end:
      guard let value = validEnd else { return }
      playback.setTrimEnd(value + delta)
      endText = playback.timecode.string(for: playback.trimSelection.end)
    }
  }

  private func synchronizeFields() {
    if focusedField != .start { startText = playback.timecode.string(for: playback.trimSelection.start) }
    if focusedField != .end { endText = playback.timecode.string(for: playback.trimSelection.end) }
  }
}

private struct CaptureTrimTimeline: View {
  let playback: CaptureReviewPlayback
  let url: URL
  @State private var thumbnails: [CGImage] = []
  @State private var draggedStart: Double?
  @State private var draggedEnd: Double?
  private let handleWidth: CGFloat = 10

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width - handleWidth * 2)
      let start = position(playback.trimSelection.start, width: width)
      let end = position(playback.trimSelection.end, width: width)
      ZStack(alignment: .leading) {
        ZStack(alignment: .leading) {
          filmstrip
          Rectangle().fill(.black.opacity(0.55))
            .frame(width: start)
          Rectangle().fill(.black.opacity(0.55))
            .frame(width: max(0, width - end))
            .offset(x: end)
        }
        .frame(width: width, height: geometry.size.height - 4)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .offset(x: handleWidth)
        .allowsHitTesting(false)
        Rectangle().strokeBorder(.yellow, lineWidth: 2)
          .frame(width: max(0, end - start), height: geometry.size.height)
          .offset(x: handleWidth + start)
          .allowsHitTesting(false)
        Rectangle().fill(.white)
          .frame(width: 2, height: geometry.size.height - 6)
          .shadow(color: .black.opacity(0.6), radius: 1)
          .offset(x: handleWidth + position(playback.time, width: width) - 1)
          .allowsHitTesting(false)
        handle(isStart: true, width: width)
          .offset(x: start)
        handle(isStart: false, width: width)
          .offset(x: handleWidth + end)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
      .coordinateSpace(name: "captureTrimTimeline")
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("captureTrimTimeline")).onChanged { value in
        playback.setScrubbing(true)
        playback.seek(to: (value.location.x - handleWidth) / width * playback.duration)
      }.onEnded { _ in playback.setScrubbing(false) })
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Trim range")
      .onKeyPress(.space) {
        playback.togglePlayback()
        return .handled
      }
    }
    .task(id: url) { await loadThumbnails() }
    .onDisappear { playback.setScrubbing(false) }
  }

  private var filmstrip: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: geometry.size.width / CGFloat(max(1, thumbnails.count)), height: geometry.size.height)
            .clipped()
        }
      }
    }
    .background(.primary.opacity(0.12))
    .accessibilityHidden(true)
  }

  private func handle(isStart: Bool, width: CGFloat) -> some View {
    UnevenRoundedRectangle(
      topLeadingRadius: isStart ? 4 : 0,
      bottomLeadingRadius: isStart ? 4 : 0,
      bottomTrailingRadius: isStart ? 0 : 4,
      topTrailingRadius: isStart ? 0 : 4
    )
    .fill(.yellow)
    .overlay {
      RoundedRectangle(cornerRadius: 1)
        .fill(.black.opacity(0.65))
        .frame(width: 2, height: 12)
    }
    .frame(width: handleWidth)
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("captureTrimTimeline")).onChanged { value in
      playback.setScrubbing(true)
      if isStart {
        if draggedStart == nil { draggedStart = playback.trimSelection.start }
        playback.setTrimStart((draggedStart ?? 0) + value.translation.width / width * playback.duration)
      } else {
        if draggedEnd == nil { draggedEnd = playback.trimSelection.end }
        playback.setTrimEnd((draggedEnd ?? playback.duration) + value.translation.width / width * playback.duration)
      }
    }.onEnded { _ in
      playback.setScrubbing(false)
      draggedStart = nil
      draggedEnd = nil
    })
    .focusable()
    .onKeyPress(.leftArrow) { adjust(isStart: isStart, direction: -1)
      return .handled
    }
    .onKeyPress(.rightArrow) { adjust(isStart: isStart, direction: 1)
      return .handled
    }
    .accessibilityLabel(isStart ? "Trim start" : "Trim end")
    .accessibilityValue(playback.timecode.string(for: isStart ? playback.trimSelection.start : playback.trimSelection.end))
    .accessibilityAdjustableAction { direction in
      adjust(isStart: isStart, direction: direction == .increment ? 1 : -1)
    }
  }

  private func adjust(isStart: Bool, direction: Int) {
    let delta = Double(direction) / playback.frameRate
    if isStart {
      playback.setTrimStart(playback.trimSelection.start + delta)
    } else {
      playback.setTrimEnd(playback.trimSelection.end + delta)
    }
  }

  private func position(_ time: Double, width: CGFloat) -> CGFloat {
    max(0, min(width, time / max(0.001, playback.duration) * width))
  }

  private func loadThumbnails() async {
    thumbnails = []
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 120, height: 80)
    for index in 0 ..< 12 {
      guard !Task.isCancelled else { return }
      let time = CMTime(seconds: playback.duration * Double(index) / 12, preferredTimescale: 60000)
      if let frame = try? await generator.image(at: time), !Task.isCancelled {
        thumbnails.append(frame.image)
      }
    }
  }
}
