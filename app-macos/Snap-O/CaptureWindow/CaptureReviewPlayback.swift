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
  private var frameDuration = 1.0 / 30
  @ObservationIgnored private var looper: AVPlayerLooper?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var seekGeneration = UUID()
  @ObservationIgnored private var isSeeking = false
  @ObservationIgnored private var pendingSeek: (time: Double, tolerance: Double)?

  var isPlaying: Bool {
    isActive && isWindowVisible && wantsPlayback && !isScrubbing
  }

  func load(_ url: URL) async {
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
      frameDuration = rate > 0 ? 1 / Double(rate) : 1 / 30
      looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
      isActive = true
      timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
        MainActor.assumeIsolated {
          guard let self, token == self.generation, !self.isScrubbing, !self.isSeeking, time.seconds.isFinite else { return }
          self.time = max(0, min(time.seconds, self.duration))
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
    seekGeneration = UUID()
    isSeeking = false
    pendingSeek = nil
    isActive = false
    isScrubbing = false
    player.pause()
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
    time = max(0, min(seconds, duration))
    pendingSeek = (time, isScrubbing ? 1.0 / 15 : 0)
    performPendingSeek()
  }

  private func performPendingSeek() {
    guard !isSeeking, let request = pendingSeek else { return }
    pendingSeek = nil
    let token = UUID()
    seekGeneration = token
    isSeeking = true
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
          guard let self, token == self.seekGeneration else { return }
          self.isSeeking = false
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
    if isPlaying, !isSeeking {
      player.playImmediately(atRate: speed)
    } else {
      player.pause()
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
