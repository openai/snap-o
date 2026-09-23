@preconcurrency import AVFoundation
import Foundation

@MainActor
final class ADBPreviewFrameSource: LivePreviewFrameSource {
  let hasIndependentFrames = false
  private let stream: ScreenStreamSession
  private var task: Task<Void, Never>?

  init(stream: ScreenStreamSession) {
    self.stream = stream
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    let decoder = H264StreamDecoder { sample, isKeyFrame in
      let event = LivePreviewFrameEvent.sample(sample, isKeyFrame: isKeyFrame)
      DispatchQueue.main.async { deliver(event) }
    } formatHandler: { format in
      let event = LivePreviewFrameEvent.format(format)
      DispatchQueue.main.async { deliver(event) }
    }
    let stream = stream
    task = Task.detached(priority: .userInitiated) {
      #if PERF_TRACING
      Perf.startupEvent("stream reader started", deviceID: stream.deviceID)
      var loggedFirstBytes = false
      #endif
      let error: Error?
      do {
        while !Task.isCancelled {
          guard let chunk = try stream.read(maxLength: 64 * 1024), !chunk.isEmpty else { break }
          #if PERF_TRACING
          if !loggedFirstBytes {
            loggedFirstBytes = true
            Perf.startupEvent("stream first bytes", deviceID: stream.deviceID)
          }
          #endif
          decoder.append(chunk)
        }
        error = nil
      } catch let failure {
        error = failure
      }
      decoder.finish()
      await deliver(.stopped(error))
    }
  }

  func stop() {
    task?.cancel()
    task = nil
    stream.close()
  }
}
