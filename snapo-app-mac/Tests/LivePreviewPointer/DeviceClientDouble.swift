import Foundation

public enum ADBDisplayRotation: Sendable { case rotation0, rotation90, rotation180, rotation270 }
public enum ADBVirtualTouchAction: Sendable { case down, move, up, cancel }
public enum ADBError: Error { case protocolFailure(String) }

public final class ADBVirtualTouchscreen: @unchecked Sendable {
  public let supportsSynchronization = true
  public let initialDisplayRotation = ADBDisplayRotation.rotation0
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
  private var rotation = ADBDisplayRotation.rotation0
  private var queryGate: CheckedContinuation<Void, Never>?
  private var shouldHoldQuery = false
  private var shouldFail = false

  public init() {}

  public func startVirtualTouchscreen(deviceID: String) throws -> ADBVirtualTouchscreen {
    touchscreen
  }

  public func setRotation(_ rotation: ADBDisplayRotation) {
    self.rotation = rotation
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

  public func displayRotation(deviceID: String) async throws -> ADBDisplayRotation {
    queryCount += 1
    if shouldHoldQuery {
      await withCheckedContinuation { queryGate = $0 }
    }
    try Task.checkCancellation()
    if shouldFail { throw ADBError.protocolFailure("Test rotation unavailable") }
    return rotation
  }
}
