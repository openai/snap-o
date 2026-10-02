@preconcurrency import AVFoundation

struct CapturePlaybackMetadata {
  let duration: Double
  let frameRate: Double
}

/// Media operations used by the playback state. Callbacks run on the main actor.
@MainActor
protocol CapturePlaybackDriver: AnyObject {
  func load(_ url: URL) async throws -> CapturePlaybackMetadata
  func configure(range: CaptureTrimRange, loops: Bool, onEnd: @escaping @MainActor () -> Void)
  func observeTime(_ onTime: @escaping @MainActor (Double) -> Void)
  func seek(to seconds: Double, tolerance: Double, completion: @escaping @MainActor () -> Void)
  func setPlaybackEnd(_ seconds: Double?)
  func play(atRate rate: Float)
  func pause()
  func stop()
}

@MainActor
final class CaptureAVPlaybackDriver: CapturePlaybackDriver {
  let player = AVQueuePlayer()
  private var asset: AVAsset?
  private var endObserver: NSObjectProtocol?
  private var timeObserver: Any?
  private var looper: AVPlayerLooper?
  private var generation = UUID()

  func load(_ url: URL) async throws -> CapturePlaybackMetadata {
    let token = generation
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let track = try await asset.loadTracks(withMediaType: .video).first
    let rate = try await track?.load(.nominalFrameRate) ?? 30
    guard !Task.isCancelled, token == generation else { throw CancellationError() }
    self.asset = asset
    return CapturePlaybackMetadata(duration: duration, frameRate: Double(rate))
  }

  func configure(range: CaptureTrimRange, loops: Bool, onEnd: @escaping @MainActor () -> Void) {
    guard let asset else { return }
    player.pause()
    clearItems()
    let item = AVPlayerItem(asset: asset)
    if loops {
      player.actionAtItemEnd = .advance
      looper = AVPlayerLooper(
        player: player, templateItem: item,
        timeRange: CMTimeRange(start: mediaTime(range.start), end: mediaTime(range.end))
      )
    } else {
      player.actionAtItemEnd = .pause
      player.insert(item, after: nil)
      endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
      ) { _ in
        MainActor.assumeIsolated { onEnd() }
      }
    }
  }

  func observeTime(_ onTime: @escaping @MainActor (Double) -> Void) {
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
      MainActor.assumeIsolated { onTime(time.seconds) }
    }
  }

  func seek(to seconds: Double, tolerance: Double, completion: @escaping @MainActor () -> Void) {
    let tolerance = mediaTime(tolerance)
    player.seek(to: mediaTime(seconds), toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
      Task { @MainActor in completion() }
    }
  }

  func setPlaybackEnd(_ seconds: Double?) {
    guard let item = player.currentItem else { return }
    if let seconds {
      let end = mediaTime(seconds)
      if item.forwardPlaybackEndTime != end { item.forwardPlaybackEndTime = end }
    } else if item.forwardPlaybackEndTime.isValid {
      item.forwardPlaybackEndTime = .invalid
    }
  }

  func play(atRate rate: Float) {
    player.playImmediately(atRate: rate)
  }

  func pause() {
    player.pause()
  }

  func stop() {
    generation = UUID()
    player.pause()
    asset = nil
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    clearItems()
  }

  private func clearItems() {
    looper?.disableLooping()
    looper = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    player.removeAllItems()
  }

  private func mediaTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60000)
  }
}
