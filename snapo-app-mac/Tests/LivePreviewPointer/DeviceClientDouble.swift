import Foundation

public enum ADBDisplayRotation: Sendable { case rotation0, rotation90, rotation180, rotation270 }
public enum ADBVirtualTouchAction: Sendable { case down, move, up, cancel }
public enum ADBError: Error { case protocolFailure(String) }

public struct ADBDisplayViewport: Sendable {
  public let rotation: ADBDisplayRotation
  public let width: Int
  public let height: Int

  public init(rotation: ADBDisplayRotation = .rotation0, width: Int = 100, height: Int = 200) {
    self.rotation = rotation
    self.width = width
    self.height = height
  }
}

public final class ADBVirtualTouchscreen: @unchecked Sendable {
  public let supportsSynchronization = true
  public let initialDisplayViewport = ADBDisplayViewport()
  private let lock = NSLock()
  private var recordedActions: [ADBVirtualTouchAction] = []
  private var recordedRotations: [ADBDisplayRotation] = []
  private var closed = false

  public init() {}

  public var actions: [ADBVirtualTouchAction] {
    lock.withLock { recordedActions }
  }

  public var rotations: [ADBDisplayRotation] {
    lock.withLock { recordedRotations }
  }

  public var isClosed: Bool {
    lock.withLock { closed }
  }

  public func send(
    action: ADBVirtualTouchAction, x: Double, y: Double,
    displayWidth: Double, displayHeight: Double, rotation: ADBDisplayRotation
  ) throws {
    try lock.withLock {
      guard !closed else { throw CancellationError() }
      recordedActions.append(action)
      recordedRotations.append(rotation)
    }
  }

  public func close() {
    lock.withLock { closed = true }
  }
}

public actor ADBClient {
  public let touchscreen = ADBVirtualTouchscreen()
  public private(set) var queryCount = 0
  private var viewport = ADBDisplayViewport()
  private var queryGate: CheckedContinuation<Void, Never>?
  private var shouldHoldQuery = false
  private var shouldFail = false

  public init() {}

  public func startVirtualTouchscreen(deviceID: String) throws -> ADBVirtualTouchscreen {
    touchscreen
  }

  public func setViewport(_ viewport: ADBDisplayViewport) {
    self.viewport = viewport
  }

  public func holdQuery() {
    shouldHoldQuery = true
  }

  public func failQueries() {
    shouldFail = true
  }

  public func releaseQuery() {
    shouldHoldQuery = false
    queryGate?.resume()
    queryGate = nil
  }

  public func displayViewport(deviceID: String) async throws -> ADBDisplayViewport {
    queryCount += 1
    if shouldHoldQuery {
      await withCheckedContinuation { queryGate = $0 }
    }
    try Task.checkCancellation()
    if shouldFail { throw ADBError.protocolFailure("Test viewport unavailable") }
    return viewport
  }
}
