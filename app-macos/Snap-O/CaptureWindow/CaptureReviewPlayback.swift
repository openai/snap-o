@preconcurrency import AVFoundation
import Observation

@MainActor
@Observable
final class CaptureReviewPlayback {
  /// State tests inject output without creating an AVFoundation player.
  @ObservationIgnored lazy var player = AVQueuePlayer()

  struct Output {
    var seek: (Double, Double, @escaping @MainActor () -> Void) -> Void
    var update: (_ rate: Float, _ end: Double?) -> Void
  }

  @ObservationIgnored private lazy var output = Output(
    seek: { [weak self] seconds, tolerance, completion in
      let tolerance = CMTime(seconds: tolerance, preferredTimescale: 60000)
      self?.player.seek(
        to: CMTime(seconds: seconds, preferredTimescale: 60000), toleranceBefore: tolerance, toleranceAfter: tolerance
      ) { _ in Task { @MainActor in completion() } }
    },
    update: { [weak self] rate, end in
      guard let self else { return }
      if rate == 0 { player.pause() }
      if isTrimming, let item = player.currentItem {
        if let end {
          let time = mediaTime(end)
          if item.forwardPlaybackEndTime != time { item.forwardPlaybackEndTime = time }
        } else if item.forwardPlaybackEndTime.isValid {
          item.forwardPlaybackEndTime = .invalid
        }
      }
      if rate != 0 { player.playImmediately(atRate: rate) }
    }
  )

  init() {}

  init(duration: Double, frameRate: Double, trim: CaptureTrimRange? = nil, output: Output) {
    self.output = output
    prepare(duration: duration, frameRate: frameRate, trim: trim)
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
    let asset = AVURLAsset(url: url)
    do {
      let seconds = try await asset.load(.duration).seconds
      guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
      let track = try await asset.loadTracks(withMediaType: .video).first
      let rate = try await track?.load(.nominalFrameRate) ?? 30
      guard !Task.isCancelled, token == generation else { return }
      self.asset = asset
      prepare(duration: seconds, frameRate: Double(rate), trim: trim)
      timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
        MainActor.assumeIsolated {
          guard let self, token == self.generation else { return }
          self.didUpdateTime(time.seconds)
        }
      }
    } catch {
      guard !Task.isCancelled, token == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func prepare(duration: Double, frameRate: Double, trim: CaptureTrimRange?) {
    self.duration = duration
    self.frameRate = frameRate.isFinite && frameRate >= 1 ? frameRate : 30
    savedTrim = trim?.isValid(for: duration) == true ? trim : nil
    configurePlayer()
    isActive = true
    seek(to: playbackRange.start)
    updatePlayback()
  }

  func didUpdateTime(_ seconds: Double) {
    guard !isScrubbing, !seeks.isSeeking, seconds.isFinite else { return }
    time = max(0, min(seconds, duration))
  }

  func didReachEnd() {
    guard isTrimming, wantsPlayback, !isScrubbing, !seeks.isSeeking else { return }
    wantsPlayback = false
    seek(to: lastPreviewFrame)
    updatePlayback()
  }

  func stop() {
    generation = UUID()
    seeks = CaptureSeekQueue()
    isActive = false
    isScrubbing = false
    output.update(0, nil)
    isTrimming = false
    savedTrim = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    looper?.disableLooping()
    looper = nil
    if asset != nil { player.removeAllItems() }
    asset = nil
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
    output.seek(request.time, request.tolerance) { [weak self] in
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
    let playing = isPlaying && !seeks.isSeeking
    // Changing the playback end during scrubbing stalls AVPlayer's pending seek.
    output.update(playing ? (isTrimming ? 1 : speed) : 0, playing && isTrimming ? trimSelection.end : nil)
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

  private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60000)
  }

  private func configurePlayer() {
    output.update(0, nil)
    seeks = CaptureSeekQueue()
    guard let asset else { return }
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
          self?.didReachEnd()
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
