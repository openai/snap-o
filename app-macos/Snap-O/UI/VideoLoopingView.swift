@preconcurrency import AVKit
import SwiftUI

struct VideoLoopingView: View {
  let url: URL
  var onFocusChange: (Bool) -> Void = { _ in }

  @State private var player: AVQueuePlayer?
  @State private var looper: AVPlayerLooper?
  @State private var visibility = PlaybackVisibility()

  var body: some View {
    Group {
      if let player {
        CaptureVideoPlayer(player: player, onFocusChange: onFocusChange)
      } else {
        // very brief fallback while preparing
        Color.black
      }
    }
    .background {
      WindowVisibilityReader { isVisible in
        updateWindowVisibility(isVisible)
      }
      .frame(width: 0, height: 0)
    }
    .onAppear {
      visibility.isViewVisible = true
      if player == nil {
        setupPlayer()
      }
      updatePlayback()
    }
    .onDisappear {
      visibility.isViewVisible = false
      player?.pause()
    }
  }

  private func setupPlayer() {
    let item = AVPlayerItem(url: url)
    let queue = AVQueuePlayer()
    let looper = AVPlayerLooper(player: queue, templateItem: item)
    player = queue
    self.looper = looper
  }

  private func updateWindowVisibility(_ isVisible: Bool) {
    guard isVisible != visibility.isWindowVisible else { return }
    visibility.updateWindowVisibility(isVisible, wasPlaying: player?.timeControlStatus != .paused)
    updatePlayback()
  }

  private func updatePlayback() {
    guard let player else { return }

    if visibility.shouldPlay {
      player.play()
    } else {
      player.pause()
    }
  }
}
