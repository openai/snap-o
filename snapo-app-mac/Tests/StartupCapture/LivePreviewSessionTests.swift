@preconcurrency import AVFoundation
import Foundation

/// A blocking stream that only ends when the production session closes it.
final class ScreenStreamSession: @unchecked Sendable {
  private let condition = NSCondition()
  private var isClosed = false

  func read(maxLength _: Int) throws -> Data? {
    condition.lock()
    defer { condition.unlock() }
    while !isClosed {
      condition.wait()
    }
    return nil
  }

  func close() {
    condition.lock()
    isClosed = true
    condition.broadcast()
    condition.unlock()
  }
}

actor ADBService {
  func exec() -> ADBService {
    self
  }

  func displayDensity(deviceID _: String) throws -> Int {
    3
  }

  func startScreenStream(deviceID _: String) throws -> ScreenStreamSession {
    ScreenStreamSession()
  }
}

final class H264StreamDecoder: @unchecked Sendable {
  @MainActor static var latest: H264StreamDecoder?
  private let formatHandler: (CMFormatDescription) -> Void

  @MainActor
  init(
    sampleHandler _: @escaping (CMSampleBuffer, Bool) -> Void,
    formatHandler: @escaping (CMFormatDescription) -> Void
  ) {
    self.formatHandler = formatHandler
    Self.latest = self
  }

  func append(_: Data) {}
  func finish() {}

  @MainActor
  func emitFormat() {
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 1080, height: 2400, extensions: nil, formatDescriptionOut: &format
    )
    guard status == noErr, let format else { fatalError("Could not make video format") }
    formatHandler(format)
  }
}

@main
@MainActor
struct LivePreviewSessionTests {
  static func main() async throws {
    let session = try await LivePreviewSession(deviceID: "ready", adb: ADBService())
    let first = Task { try await session.waitUntilReady() }
    let second = Task { try await session.waitUntilReady() }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    H264StreamDecoder.latest?.emitFormat()
    let firstMedia = try await first.value
    let secondMedia = try await second.value
    precondition(firstMedia == secondMedia)
    precondition(firstMedia.size == CGSize(width: 1080, height: 2400))
    session.cancel()
    _ = await session.waitUntilStop()

    let cancelled = try await LivePreviewSession(deviceID: "cancelled", adb: ADBService())
    let pendingFirst = Task { try await cancelled.waitUntilReady() }
    let pendingSecond = Task { try await cancelled.waitUntilReady() }
    for _ in 0 ..< 20 {
      await Task.yield()
    }
    cancelled.cancel()
    await expectCancellation(pendingFirst)
    await expectCancellation(pendingSecond)
    await expectCancellation(Task { try await cancelled.waitUntilReady() })
    _ = await cancelled.waitUntilStop()
    print("Live preview session tests passed (readiness and cancellation)")
  }

  static func expectCancellation(_ task: Task<Media, Error>) async {
    do {
      _ = try await task.value
      fatalError("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    } catch {
      fatalError("Unexpected error: \(error)")
    }
  }
}
