@preconcurrency import AVFoundation
import Dependencies
import Observation

@MainActor
@Observable
final class CaptureReviewPlayback {
  var player: AVQueuePlayer? {
    driver.player
  }

  @ObservationIgnored private let driver: any CapturePlaybackDriver

  init(driver: any CapturePlaybackDriver = AVPlaybackDriver()) {
    self.driver = driver
  }

  private(set) var duration: Double = 0
  private(set) var time: Double = 0
  private(set) var wantsPlayback = true
  private(set) var speed: Float = 1
  private(set) var isScrubbing = false
  private(set) var errorMessage: String?
  private var isWindowVisible = false
  private var isPaneVisible = true
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

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var seeks = CaptureSeekQueue()

  var isPlaying: Bool {
    isActive && isWindowVisible && isPaneVisible && wantsPlayback && !isScrubbing
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
    @Dependency(\.videoFiles)
    var videoFiles
    do {
      let info = try await videoFiles.inspect(url)
      let seconds = info.duration
      guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
      let rate = info.frameRate
      guard !Task.isCancelled, token == generation else { return }
      duration = seconds
      frameRate = rate.isFinite && rate >= 1 ? Double(rate) : 30
      trimSession = CaptureTrimSession(duration: seconds, frameRate: frameRate, trim: trim)
      driver.load(url) { [weak self] time in
        guard let self, token == generation, !self.isScrubbing, !self.seeks.isSeeking, time.isFinite else { return }
        self.time = max(0, min(time, duration))
      }
      configurePlayer()
      isActive = true
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
    driver.stop()
    trimSession = CaptureTrimSession()
    time = 0
    duration = 0
  }

  func setPaneVisible(_ visible: Bool) {
    isPaneVisible = visible
    updatePlayback()
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
    driver.seek(request) { [weak self] in
      guard let self, seeks.complete(request) else { return }
      performPendingSeek()
      updatePlayback()
    }
  }

  func stepFrame(_ direction: Int) {
    wantsPlayback = false
    updatePlayback()
    seek(to: time + Double(direction) * frameDuration)
  }

  private func updatePlayback() {
    let rate: Float? = isPlaying && !seeks.isSeeking ? (isTrimming ? 1 : speed) : nil
    driver.setPlayback(rate: rate, end: isTrimming && rate != nil ? trimSelection.end : nil)
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

  private func configurePlayer() {
    seeks = CaptureSeekQueue()
    driver.configure(range: playbackRange, isTrimming: isTrimming) { [weak self] in
      guard let self, isTrimming, wantsPlayback, !self.isScrubbing, !self.seeks.isSeeking else { return }
      wantsPlayback = false
      seek(to: lastPreviewFrame)
      updatePlayback()
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

@MainActor
protocol CapturePlaybackDriver: AnyObject {
  var player: AVQueuePlayer? { get }
  func load(_ url: URL, onTime: @escaping @MainActor (Double) -> Void)
  func configure(range: CaptureTrimRange, isTrimming: Bool, onEnd: @escaping @MainActor () -> Void)
  func setPlayback(rate: Float?, end: Double?)
  func seek(_ request: CaptureSeekQueue.Request, completion: @escaping @MainActor () -> Void)
  func stop()
}

@MainActor
final class AVPlaybackDriver: CapturePlaybackDriver {
  let player: AVQueuePlayer? = AVQueuePlayer()
  private var asset: AVAsset?
  private var endObserver: NSObjectProtocol?
  private var looper: AVPlayerLooper?
  private var timeObserver: Any?

  func load(_ url: URL, onTime: @escaping @MainActor (Double) -> Void) {
    asset = AVURLAsset(url: url)
    timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
      MainActor.assumeIsolated { onTime(time.seconds) }
    }
  }

  func configure(range: CaptureTrimRange, isTrimming: Bool, onEnd: @escaping @MainActor () -> Void) {
    guard let asset, let player else { return }
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
      ) { _ in MainActor.assumeIsolated { onEnd() } }
    } else {
      player.actionAtItemEnd = .advance
      looper = AVPlayerLooper(
        player: player,
        templateItem: item,
        timeRange: CMTimeRange(start: mediaTime(range.start), end: mediaTime(range.end))
      )
    }
  }

  func setPlayback(rate: Float?, end: Double?) {
    guard let player else { return }
    if let rate {
      if let end, let item = player.currentItem {
        let time = mediaTime(end)
        if item.forwardPlaybackEndTime != time { item.forwardPlaybackEndTime = time }
      }
      player.playImmediately(atRate: rate)
    } else {
      player.pause()
      // Changing the playback end during scrubbing stalls AVPlayer's pending seek.
      if let item = player.currentItem, item.forwardPlaybackEndTime.isValid {
        item.forwardPlaybackEndTime = .invalid
      }
    }
  }

  func seek(_ request: CaptureSeekQueue.Request, completion: @escaping @MainActor () -> Void) {
    let tolerance = mediaTime(request.tolerance)
    player?.seek(to: mediaTime(request.time), toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
      Task { @MainActor in completion() }
    }
  }

  func stop() {
    player?.pause()
    asset = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
    looper?.disableLooping()
    looper = nil
    player?.removeAllItems()
  }

  private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60000)
  }
}
