import Foundation

/// Trim selection, playback intent, and pending seeks, independent of media decoding.
struct CapturePlaybackState {
  private(set) var duration = 0.0
  private(set) var frameRate = 30.0
  private(set) var time = 0.0
  private(set) var wantsPlayback = true
  private(set) var speed: Float = 1
  private(set) var isScrubbing = false
  private(set) var isTrimming = false
  private(set) var trimSelection = CaptureTrimRange(start: 0, end: 0)
  private var isWindowVisible = false
  private var savedTrim: CaptureTrimRange?
  private var timeBeforeTrimming = 0.0
  private var wasPlayingBeforeTrimming = false
  private var seeks = CaptureSeekQueue()

  init(duration: Double = 0, frameRate: Double = 30, trim: CaptureTrimRange? = nil) {
    if duration > 0 { load(duration: duration, frameRate: frameRate, trim: trim) }
  }

  var frameDuration: Double {
    1 / frameRate
  }

  var canTrim: Bool {
    duration > frameDuration
  }

  var isPlaying: Bool {
    duration > 0 && isWindowVisible && wantsPlayback && !isScrubbing
  }

  var isSeeking: Bool {
    seeks.isSeeking
  }

  var playbackRange: CaptureTrimRange {
    isTrimming ? trimSelection : savedTrim ?? CaptureTrimRange(start: 0, end: duration)
  }

  var elapsedTime: Double {
    max(0, time - playbackRange.start)
  }

  var playbackRate: Float {
    isPlaying && !isSeeking ? (isTrimming ? 1 : speed) : 0
  }

  var playbackEnd: Double? {
    isPlaying && !isSeeking && isTrimming ? trimSelection.end : nil
  }

  private var lastPreviewFrame: Double {
    max(playbackRange.start, playbackRange.end - frameDuration)
  }

  mutating func load(duration: Double, frameRate: Double, trim: CaptureTrimRange?) {
    self.duration = duration
    self.frameRate = frameRate.isFinite && frameRate >= 1 ? frameRate : 30
    savedTrim = trim?.isValid(for: duration) == true ? trim : nil
    wantsPlayback = true
    seeks = CaptureSeekQueue()
    seek(to: playbackRange.start)
  }

  mutating func stop() {
    seeks = CaptureSeekQueue()
    isScrubbing = false
    isTrimming = false
    savedTrim = nil
    time = 0
    duration = 0
  }

  mutating func setWindowVisible(_ visible: Bool) {
    isWindowVisible = visible
  }

  mutating func setSpeed(_ value: Float) {
    speed = value
  }

  mutating func togglePlayback() {
    if !wantsPlayback, isTrimming, time >= lastPreviewFrame - frameDuration / 2 {
      seek(to: playbackRange.start)
    }
    wantsPlayback.toggle()
  }

  mutating func setScrubbing(_ editing: Bool) {
    guard isScrubbing != editing else { return }
    isScrubbing = editing
    if !editing { seek(to: time) }
  }

  mutating func seek(to seconds: Double) {
    guard seconds.isFinite else { return }
    time = max(playbackRange.start, min(seconds, isTrimming ? lastPreviewFrame : playbackRange.end))
    seeks.enqueue(time: time, tolerance: isScrubbing ? 1.0 / 15 : 0)
  }

  mutating func nextSeek() -> CaptureSeekQueue.Request? {
    seeks.next()
  }

  mutating func completeSeek(_ request: CaptureSeekQueue.Request) -> Bool {
    seeks.complete(request)
  }

  mutating func stepFrame(_ direction: Int) {
    wantsPlayback = false
    seek(to: time + Double(direction) * frameDuration)
  }

  mutating func didUpdateTime(_ seconds: Double) {
    guard !isScrubbing, !isSeeking, seconds.isFinite else { return }
    time = max(0, min(seconds, duration))
  }

  mutating func didReachEnd() {
    guard isTrimming, wantsPlayback, !isScrubbing, !isSeeking else { return }
    wantsPlayback = false
    seek(to: lastPreviewFrame)
  }

  @discardableResult
  mutating func beginTrimming() -> Bool {
    guard canTrim, !isTrimming else { return false }
    timeBeforeTrimming = time
    wasPlayingBeforeTrimming = wantsPlayback
    trimSelection = playbackRange
    isTrimming = true
    wantsPlayback = false
    seeks = CaptureSeekQueue()
    seek(to: trimSelection.start)
    return true
  }

  @discardableResult
  mutating func cancelTrimming() -> Bool {
    guard isTrimming else { return false }
    isTrimming = false
    wantsPlayback = wasPlayingBeforeTrimming
    seeks = CaptureSeekQueue()
    seek(to: timeBeforeTrimming)
    return true
  }

  mutating func confirmTrim() -> CaptureTrimRange? {
    guard isTrimming else { return savedTrim }
    savedTrim = trimSelection == CaptureTrimRange(start: 0, end: duration) ? nil : trimSelection
    isTrimming = false
    wantsPlayback = false
    seeks = CaptureSeekQueue()
    seek(to: playbackRange.start)
    return savedTrim
  }

  mutating func setTrimStart(_ seconds: Double) {
    guard isTrimming, seconds.isFinite else { return }
    let start = min(max(0, snapped(seconds)), max(0, trimSelection.end - frameDuration))
    trimSelection = CaptureTrimRange(start: start, end: trimSelection.end)
    wantsPlayback = false
    seek(to: start)
  }

  mutating func setTrimEnd(_ seconds: Double) {
    guard isTrimming, seconds.isFinite else { return }
    let end = max(min(duration, snapped(seconds)), trimSelection.start + frameDuration)
    trimSelection = CaptureTrimRange(start: trimSelection.start, end: min(duration, end))
    wantsPlayback = false
    seek(to: lastPreviewFrame)
  }

  private func snapped(_ seconds: Double) -> Double {
    (seconds * frameRate).rounded() / frameRate
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
    active != nil || pending != nil
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
