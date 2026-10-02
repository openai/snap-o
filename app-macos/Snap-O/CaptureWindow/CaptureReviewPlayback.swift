@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable
final class CaptureReviewPlayback {
  let player = AVQueuePlayer()
  private(set) var duration: Double = 0
  private(set) var time: Double = 0
  private(set) var wantsPlayback = true
  private(set) var speed: Float = 1
  private(set) var isScrubbing = false
  private(set) var errorMessage: String?
  private var isWindowVisible = false
  private var isActive = false
  private(set) var frameRate = 30.0
  private var trimSession = CaptureTrimSession()
  var isTrimming: Bool {
    trimSession.isEditing
  }

  var trimSelection: CaptureTrimRange {
    trimSession.selection
  }

  private var frameDuration: Double {
    1 / frameRate
  }

  @ObservationIgnored private var asset: AVAsset?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private var looper: AVPlayerLooper?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var seeks = CaptureSeekQueue()

  var isPlaying: Bool {
    isActive && isWindowVisible && wantsPlayback && !isScrubbing
  }

  var playbackRange: CaptureTrimRange {
    trimSession.range
  }

  var elapsedTime: Double {
    max(0, time - playbackRange.start)
  }

  var timecode: CaptureTrimTimecode {
    CaptureTrimTimecode(frameRate: frameRate)
  }

  var canTrim: Bool {
    isActive && duration > frameDuration
  }

  func load(_ url: URL, trim: CaptureTrimRange? = nil) async {
    stop()
    let token = generation
    errorMessage = nil
    wantsPlayback = true
    let asset = AVURLAsset(url: url)
    do {
      let seconds = try await asset.load(.duration).seconds
      guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
      let track = try await asset.loadTracks(withMediaType: .video).first
      let rate = try await track?.load(.nominalFrameRate) ?? 30
      guard !Task.isCancelled, token == generation else { return }
      duration = seconds
      frameRate = rate.isFinite && rate >= 1 ? Double(rate) : 30
      self.asset = asset
      trimSession = CaptureTrimSession(duration: seconds, frameRate: frameRate, trim: trim)
      configurePlayer()
      isActive = true
      timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
        MainActor.assumeIsolated {
          guard let self, token == self.generation, !self.isScrubbing, !self.seeks.isSeeking, time.seconds.isFinite else { return }
          self.time = max(0, min(time.seconds, self.duration))
        }
      }
      seek(to: playbackRange.start)
      updatePlayback()
    } catch {
      guard !Task.isCancelled, token == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  func stop() {
    generation = UUID()
    seeks = CaptureSeekQueue()
    isActive = false
    isScrubbing = false
    player.pause()
    trimSession = CaptureTrimSession()
    asset = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    looper?.disableLooping()
    looper = nil
    player.removeAllItems()
    time = 0
    duration = 0
  }

  func setWindowVisible(_ visible: Bool) {
    isWindowVisible = visible
    updatePlayback()
  }

  func togglePlayback() {
    if !wantsPlayback, isTrimming, time >= lastPreviewFrame - frameDuration / 2 {
      seek(to: playbackRange.start)
    }
    wantsPlayback.toggle()
    updatePlayback()
  }

  func setSpeed(_ value: Float) {
    speed = value
    updatePlayback()
  }

  func setScrubbing(_ editing: Bool) {
    guard isScrubbing != editing else { return }
    isScrubbing = editing
    if !editing { seek(to: time) }
    updatePlayback()
  }

  func seek(to seconds: Double) {
    guard seconds.isFinite else { return }
    time = max(playbackRange.start, min(seconds, isTrimming ? lastPreviewFrame : playbackRange.end))
    seeks.enqueue(time: time, tolerance: isScrubbing ? 1.0 / 15 : 0)
    performPendingSeek()
  }

  private func performPendingSeek() {
    guard let request = seeks.next() else { return }
    updatePlayback()
    let tolerance = CMTime(seconds: request.tolerance, preferredTimescale: 60000)
    // Finish the current decode, then jump to the latest requested position.
    player
      .seek(
        to: CMTime(seconds: request.time, preferredTimescale: 60000),
        toleranceBefore: tolerance,
        toleranceAfter: tolerance
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.seeks.complete(request) else { return }
          self.performPendingSeek()
          self.updatePlayback()
        }
      }
  }

  func stepFrame(_ direction: Int) {
    wantsPlayback = false
    updatePlayback()
    seek(to: time + Double(direction) * frameDuration)
  }

  private func updatePlayback() {
    if isPlaying, !seeks.isSeeking {
      if isTrimming, let item = player.currentItem {
        let end = mediaTime(trimSelection.end)
        if item.forwardPlaybackEndTime != end { item.forwardPlaybackEndTime = end }
      }
      player.playImmediately(atRate: isTrimming ? 1 : speed)
    } else {
      player.pause()
      // Changing the playback end during scrubbing stalls AVPlayer's pending seek.
      if isTrimming, let item = player.currentItem, item.forwardPlaybackEndTime.isValid {
        item.forwardPlaybackEndTime = .invalid
      }
    }
  }

  func beginTrimming() {
    guard canTrim, trimSession.begin(time: time, playing: wantsPlayback) else { return }
    wantsPlayback = false
    configurePlayer()
    seek(to: trimSelection.start)
  }

  func cancelTrimming() {
    guard let playback = trimSession.cancel() else { return }
    wantsPlayback = playback.playing
    configurePlayer()
    seek(to: playback.time)
  }

  func confirmTrim() -> CaptureTrimRange? {
    guard isTrimming else { return trimSession.confirm() }
    let trim = trimSession.confirm()
    wantsPlayback = false
    configurePlayer()
    seek(to: playbackRange.start)
    return trim
  }

  func setTrimStart(_ seconds: Double) {
    guard isTrimming, seconds.isFinite else { return }
    trimSession.setStart(seconds)
    previewTrimBoundary(trimSelection.start)
  }

  func setTrimEnd(_ seconds: Double) {
    guard isTrimming, seconds.isFinite else { return }
    trimSession.setEnd(seconds)
    previewTrimBoundary(lastPreviewFrame)
  }

  private var lastPreviewFrame: Double {
    max(playbackRange.start, playbackRange.end - frameDuration)
  }

  private func previewTrimBoundary(_ seconds: Double) {
    wantsPlayback = false
    seek(to: seconds)
    updatePlayback()
  }

  private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60000)
  }

  private func configurePlayer() {
    guard let asset else { return }
    player.pause()
    seeks = CaptureSeekQueue()
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
          guard let self, self.isTrimming, self.wantsPlayback, !self.isScrubbing, !self.seeks.isSeeking else { return }
          self.wantsPlayback = false
          self.seek(to: self.lastPreviewFrame)
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

/// Coalesces pending scrubs while the player finishes its current seek.
struct CaptureSeekQueue {
  struct Request {
    let id = UUID()
    let time: Double
    let tolerance: Double
  }

  private var active: UUID?
  private var pending: Request?
  var isSeeking: Bool {
    active != nil
  }

  mutating func enqueue(time: Double, tolerance: Double) {
    pending = Request(time: time, tolerance: tolerance)
  }

  mutating func next() -> Request? {
    guard active == nil, let request = pending else { return nil }
    pending = nil
    active = request.id
    return request
  }

  mutating func complete(_ request: Request) -> Bool {
    guard active == request.id else { return false }
    active = nil
    return true
  }
}
