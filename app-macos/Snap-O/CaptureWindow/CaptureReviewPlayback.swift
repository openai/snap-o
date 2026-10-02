@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable
final class CaptureReviewPlayback {
  let player = AVQueuePlayer()
  private var state = CapturePlaybackState()
  private(set) var errorMessage: String?

  var duration: Double {
    state.duration
  }

  var time: Double {
    state.time
  }

  var wantsPlayback: Bool {
    state.wantsPlayback
  }

  var speed: Float {
    state.speed
  }

  var isScrubbing: Bool {
    state.isScrubbing
  }

  var frameRate: Double {
    state.frameRate
  }

  var isTrimming: Bool {
    state.isTrimming
  }

  var trimSelection: CaptureTrimRange {
    state.trimSelection
  }

  @ObservationIgnored private var asset: AVAsset?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private var looper: AVPlayerLooper?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var generation = UUID()

  var isPlaying: Bool {
    state.isPlaying
  }

  var playbackRange: CaptureTrimRange {
    state.playbackRange
  }

  var elapsedTime: Double {
    state.elapsedTime
  }

  var timecode: CaptureTrimTimecode {
    CaptureTrimTimecode(frameRate: frameRate)
  }

  var canTrim: Bool {
    state.canTrim
  }

  func load(_ url: URL, trim: CaptureTrimRange? = nil) async {
    stop()
    let token = generation
    errorMessage = nil
    let asset = AVURLAsset(url: url)
    do {
      let seconds = try await asset.load(.duration).seconds
      guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
      let track = try await asset.loadTracks(withMediaType: .video).first
      let rate = try await track?.load(.nominalFrameRate) ?? 30
      guard !Task.isCancelled, token == generation else { return }
      state.load(duration: seconds, frameRate: Double(rate), trim: trim)
      self.asset = asset
      configurePlayer()
      timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
        MainActor.assumeIsolated {
          guard let self, token == self.generation else { return }
          self.state.didUpdateTime(time.seconds)
        }
      }
      updatePlayback()
    } catch {
      guard !Task.isCancelled, token == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  func stop() {
    generation = UUID()
    state.stop()
    player.pause()
    asset = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    looper?.disableLooping()
    looper = nil
    player.removeAllItems()
  }

  func setWindowVisible(_ visible: Bool) {
    state.setWindowVisible(visible)
    updatePlayback()
  }

  func togglePlayback() {
    state.togglePlayback()
    updatePlayback()
  }

  func setSpeed(_ value: Float) {
    state.setSpeed(value)
    updatePlayback()
  }

  func setScrubbing(_ editing: Bool) {
    state.setScrubbing(editing)
    updatePlayback()
  }

  func seek(to seconds: Double) {
    state.seek(to: seconds)
    updatePlayback()
  }

  private func performSeek(_ request: CaptureSeekQueue.Request) {
    let tolerance = CMTime(seconds: request.tolerance, preferredTimescale: 60000)
    // Finish the current decode, then jump to the latest requested position.
    player
      .seek(
        to: CMTime(seconds: request.time, preferredTimescale: 60000),
        toleranceBefore: tolerance,
        toleranceAfter: tolerance
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.state.completeSeek(request) else { return }
          self.updatePlayback()
        }
      }
  }

  func stepFrame(_ direction: Int) {
    state.stepFrame(direction)
    updatePlayback()
  }

  private func updatePlayback() {
    let request = state.nextSeek()
    if isPlaying, !state.isSeeking {
      if let seconds = state.playbackEnd, let item = player.currentItem {
        let end = mediaTime(seconds)
        if item.forwardPlaybackEndTime != end { item.forwardPlaybackEndTime = end }
      }
      player.playImmediately(atRate: state.playbackRate)
    } else {
      player.pause()
      // Changing the playback end during scrubbing stalls AVPlayer's pending seek.
      if isTrimming, let item = player.currentItem, item.forwardPlaybackEndTime.isValid {
        item.forwardPlaybackEndTime = .invalid
      }
    }
    if let request { performSeek(request) }
  }

  func beginTrimming() {
    guard state.beginTrimming() else { return }
    configurePlayer()
    updatePlayback()
  }

  func cancelTrimming() {
    guard state.cancelTrimming() else { return }
    configurePlayer()
    updatePlayback()
  }

  func confirmTrim() -> CaptureTrimRange? {
    let wasTrimming = isTrimming
    let trim = state.confirmTrim()
    if wasTrimming {
      configurePlayer()
      updatePlayback()
    }
    return trim
  }

  func setTrimStart(_ seconds: Double) {
    state.setTrimStart(seconds)
    updatePlayback()
  }

  func setTrimEnd(_ seconds: Double) {
    state.setTrimEnd(seconds)
    updatePlayback()
  }

  private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60000)
  }

  private func configurePlayer() {
    guard let asset else { return }
    player.pause()
    looper?.disableLooping()
    looper = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    player.removeAllItems()
    let item = AVPlayerItem(asset: asset)
    if isTrimming {
      player.actionAtItemEnd = .pause
      player.insert(item, after: nil)
      endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.state.didReachEnd()
          self.updatePlayback()
        }
      }
    } else {
      player.actionAtItemEnd = .advance
      looper = AVPlayerLooper(
        player: player, templateItem: item,
        timeRange: CMTimeRange(start: mediaTime(playbackRange.start), end: mediaTime(playbackRange.end))
      )
    }
  }

  static func timestamp(_ seconds: Double) -> String {
    let total = seconds.isFinite ? max(0, Int(seconds)) : 0
    if total >= 3600 {
      return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
  }
}
