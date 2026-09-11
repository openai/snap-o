@preconcurrency import AVKit
import SwiftUI

struct VideoLoopingView: View {
  let url: URL

  @State private var player: AVQueuePlayer?
  @State private var looper: AVPlayerLooper?
  @State private var isViewVisible = false
  @State private var isWindowVisible = false
  @State private var shouldResumeWhenVisible = true

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
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
      isViewVisible = true
      if player == nil {
        setupPlayer()
      }
      updatePlayback()
    }
    .onDisappear {
      isViewVisible = false
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
    guard isVisible != isWindowVisible else { return }

    if !isVisible, let player {
      shouldResumeWhenVisible = player.timeControlStatus != .paused
    }

    isWindowVisible = isVisible
    updatePlayback()
  }

  private func updatePlayback() {
    guard let player else { return }

    if isViewVisible, isWindowVisible, shouldResumeWhenVisible {
      player.play()
    } else {
      player.pause()
    }
  }
}
