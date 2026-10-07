import Foundation

/// Proves that new sockets still reach the server that supplied device discovery.
/// ADB reuses transport IDs after restart and exposes no server instance token.
/// Keep an unselected smart socket open, then request its version only after
/// the replacement guard connects and the operation completes its handshake.
/// The reply proves the old server was alive after those connections reached it. The version value itself
/// is not an identity. This also works through a tunnel to one ADB server.
/// Each version request closes its socket, so the next unselected socket takes over.
final class ADBServerSession: DeviceServerConnection, @unchecked Sendable {
  let id = UUID()
  let serverID: ADBServerID
  private let stateLock = NSLock()
  private let verificationLock = NSLock()
  private let connectionFactory: @Sendable () throws -> any ADBConnection
  private let timeout: Duration
  private var closed = false
  private var guardConnection: (any ADBConnection)?
  private var connections: [ObjectIdentifier: any ADBConnection] = [:]
  private var targets: [WeakTarget] = []

  private struct WeakTarget {
    weak var value: DeviceTarget?
  }

  init(
    tracking: any ADBConnection,
    timeout: Duration,
    serverID: ADBServerID = .local,
    connectionFactory: @escaping @Sendable () throws -> any ADBConnection
  ) {
    self.serverID = serverID
    self.timeout = timeout
    self.connectionFactory = connectionFactory
    connections[ObjectIdentifier(tracking)] = tracking
  }

  /// The caller owns this socket; binding it registers target invalidation.
  func makeOperationConnection() throws -> any ADBConnection {
    try stateLock.withLock { try requireOpen() }
    let connection = try connectionFactory()
    do {
      try stateLock.withLock { try requireOpen() }
      return connection
    } catch {
      connection.close()
      throw error
    }
  }

  func register(_ target: DeviceTarget) {
    let rejected = stateLock.withLock {
      guard !closed else { return true }
      targets.removeAll { $0.value == nil }
      targets.append(WeakTarget(value: target))
      return false
    }
    if rejected { target.invalidate() }
  }

  func close() {
    let owned = stateLock.withLock {
      closed = true
      let owned = (Array(connections.values), targets.compactMap(\.value))
      connections.removeAll()
      targets.removeAll()
      guardConnection = nil
      return owned
    }
    for connection in owned.0 {
      connection.close()
    }
    for target in owned.1 {
      target.invalidate()
    }
  }

  /// The initial list only supplies a candidate. Publish the replacement stream instead.
  func prepareTracking(transportID: String, replacing initial: any ADBConnection) throws -> any ADBConnection {
    let seed = try openConnection()
    do {
      try seed.withRequestTimeout(timeout) { try seed.sendTransportID(transportID) }
      try stateLock.withLock {
        try requireOpen()
        guardConnection = seed
      }
      let tracking = try openConnection()
      try verifyConnection {
        try tracking.withRequestTimeout(timeout) { try tracking.sendTrackDevices() }
      }
      release(initial)
      return tracking
    } catch {
      close()
      throw error
    }
  }

  func verifyConnection(selecting: () throws -> Void) throws {
    try verificationLock.withLock {
      let previous = try stateLock.withLock {
        try requireOpen()
        guard let guardConnection else {
          throw ADBError.protocolFailure("ADB server connection has not been established.")
        }
        return guardConnection
      }
      let next = try openConnection()
      do {
        // Keep the guard independent of devices: ADB closes selected sockets on device loss.
        // Its TCP connection and the operation's handshake precede the old server's reply.
        try selecting()
      } catch {
        release(next)
        throw error
      }
      do {
        try previous.withRequestTimeout(timeout) {
          guard let version = try previous.sendHostCommand("host:version", expectsResponse: true),
                version.count == 4, UInt16(version, radix: 16) != nil else {
            throw ADBError.protocolFailure("Invalid ADB server reply.")
          }
        }
        try stateLock.withLock {
          try requireOpen()
          guardConnection = next
        }
        release(previous)
      } catch {
        // A failed old-server round trip invalidates every target from this discovery.
        close()
        throw error
      }
    }
  }

  private func requireOpen() throws {
    guard !closed else { throw ADBError.protocolFailure("The ADB server connection is no longer available.") }
  }

  private func openConnection() throws -> any ADBConnection {
    try stateLock.withLock { try requireOpen() }
    let connection = try connectionFactory()
    do {
      try stateLock.withLock {
        try requireOpen()
        connections[ObjectIdentifier(connection)] = connection
      }
      return connection
    } catch {
      connection.close()
      throw error
    }
  }

  private func release(_ connection: any ADBConnection) {
    _ = stateLock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    connection.close()
  }
}
