import Foundation

/// Selects native or scaled streams without tying size discovery to transport failure.
enum EmulatorPreviewStream {
  struct DisplayChange {
    let size: CGSize?
  }

  static func run(
    requestedSize: LivePreviewFrameSize,
    isolation: isolated (any Actor)? = #isolation,
    readDisplaySize: () async throws -> CGSize?,
    receiveFrames: (LivePreviewFrameSize, CGSize?) async throws -> DisplayChange?
  ) async throws {
    try Task.checkCancellation()
    var nativeSize: CGSize?
    if case .preview = requestedSize {
      nativeSize = try await readSize(readDisplaySize)
    }
    while true {
      try Task.checkCancellation()
      let change = try await receiveFrames(requestedSize.capped(to: nativeSize), nativeSize)
      try Task.checkCancellation()
      guard let change else { return }
      nativeSize = change.size
    }
  }

  static func readSize(
    _ read: () async throws -> CGSize?,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> CGSize? {
    do {
      let size = try await read()
      try Task.checkCancellation()
      return size
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return nil
    }
  }
}
