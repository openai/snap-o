@preconcurrency import AVKit
import SwiftUI

struct VideoLoopingView: View {
  let url: URL

  @State private var player: AVQueuePlayer?
  @State private var looper: AVPlayerLooper?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
          .onAppear { player.play() }
          .onDisappear { player.pause() }
      } else {
        // very brief fallback while preparing
        Color.black
      }
    }
    .task {
      await setupPlayer()
    }
  }

  private func setupPlayer() async {
    // Build looping playback
    let item = AVPlayerItem(url: url)
    let queue = AVQueuePlayer()
    let looper = AVPlayerLooper(player: queue, templateItem: item)
    player = queue
    self.looper = looper
    queue.play()
  }
}
