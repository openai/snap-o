@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable
final class CaptureReviewPlayback {
  var player: AVQueuePlayer? {
    (driver as? CaptureAVPlaybackDriver)?.player
  }

  @ObservationIgnored private let driver: any CapturePlaybackDriver

  init(driver: any CapturePlaybackDriver = CaptureAVPlaybackDriver()) {
    self.driver = driver
  }

  private(set) var duration: Double = 0
  private(set) var time: Double = 0
  private(set) var wantsPlayback = true
  private(set) var speed: Float = 1
  private(set) var isScrubbing = false
  private(set) var errorMessage: String?
  private var isWindowVisible = false
  private var isActive = false
  private(set) var frameRate = 30.0
  private(set) var isTrimming = false
  private(set) var trimSelection = CaptureTrimRange(start: 0, end: 0)
  private var savedTrim: CaptureTrimRange?
  private var timeBeforeTrimming = 0.0
  private var wasPlayingBeforeTrimming = false
  private var frameDuration: Double {
    1 / frameRate
  }

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var seeks = CaptureSeekQueue()

  var isPlaying: Bool {
    isActive && isWindowVisible && wantsPlayback && !isScrubbing
  }

  var playbackRange: CaptureTrimRange {
    isTrimming ? trimSelection : savedTrim ?? CaptureTrimRange(start: 0, end: duration)
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
    do {
      let metadata = try await driver.load(url)
      guard !Task.isCancelled, token == generation else { return }
      let seconds = metadata.duration
      guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
      duration = seconds
      frameRate = metadata.frameRate.isFinite && metadata.frameRate >= 1 ? metadata.frameRate : 30
      savedTrim = trim?.isValid(for: seconds) == true ? trim : nil
      configurePlayer()
      isActive = true
      driver.observeTime { [weak self] seconds in
        guard let self, token == generation, !self.isScrubbing, !self.seeks.isSeeking, seconds.isFinite else { return }
        time = max(0, min(seconds, duration))
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
    driver.pause()
    isTrimming = false
    savedTrim = nil
    driver.stop()
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
    // Finish the current decode, then jump to the latest requested position.
    driver.seek(to: request.time, tolerance: request.tolerance) { [weak self] in
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
    if isPlaying, !seeks.isSeeking {
      if isTrimming { driver.setPlaybackEnd(trimSelection.end) }
      driver.play(atRate: isTrimming ? 1 : speed)
    } else {
      driver.pause()
      // Changing the playback end during scrubbing stalls AVPlayer's pending seek.
      if isTrimming { driver.setPlaybackEnd(nil) }
    }
  }

  func beginTrimming() {
    guard canTrim, !isTrimming else { return }
    timeBeforeTrimming = time
    wasPlayingBeforeTrimming = wantsPlayback
    trimSelection = playbackRange
    isTrimming = true
    wantsPlayback = false
    configurePlayer()
    seek(to: trimSelection.start)
  }

  func cancelTrimming() {
    guard isTrimming else { return }
    isTrimming = false
    wantsPlayback = wasPlayingBeforeTrimming
    configurePlayer()
    seek(to: timeBeforeTrimming)
  }

  func confirmTrim() -> CaptureTrimRange? {
    guard isTrimming else { return savedTrim }
    savedTrim = trimSelection == CaptureTrimRange(start: 0, end: duration) ? nil : trimSelection
    isTrimming = false
    wantsPlayback = false
    configurePlayer()
    seek(to: playbackRange.start)
    return savedTrim
  }

  func setTrimStart(_ seconds: Double) {
    guard isTrimming, seconds.isFinite else { return }
    let start = min(max(0, snapped(seconds)), max(0, trimSelection.end - frameDuration))
    trimSelection = CaptureTrimRange(start: start, end: trimSelection.end)
    previewTrimBoundary(start)
  }

  func setTrimEnd(_ seconds: Double) {
    guard isTrimming, seconds.isFinite else { return }
    let end = max(min(duration, snapped(seconds)), trimSelection.start + frameDuration)
    trimSelection = CaptureTrimRange(start: trimSelection.start, end: min(duration, end))
    previewTrimBoundary(lastPreviewFrame)
  }

  private var lastPreviewFrame: Double {
    max(playbackRange.start, playbackRange.end - frameDuration)
  }

  private func snapped(_ seconds: Double) -> Double {
    (seconds * frameRate).rounded() / frameRate
  }

  private func previewTrimBoundary(_ seconds: Double) {
    wantsPlayback = false
    seek(to: seconds)
    updatePlayback()
  }

  private func configurePlayer() {
    driver.pause()
    seeks = CaptureSeekQueue()
    driver.configure(range: playbackRange, loops: !isTrimming) { [weak self] in
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
