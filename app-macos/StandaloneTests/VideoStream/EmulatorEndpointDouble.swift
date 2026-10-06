import Foundation

final class EmulatorEndpointProbe: @unchecked Sendable {
  let gate: TestGate?
  private let lock = NSLock()
  private var requests = 0
  private var closes = 0
  var requestCount: Int {
    lock.withLock { requests }
  }

  var closeCount: Int {
    lock.withLock { closes }
  }

  init(gate: TestGate? = nil) {
    self.gate = gate
  }

  func request() async -> EmulatorGRPCEndpoint? {
    lock.withLock { requests += 1 }
    testChanges.signal()
    await gate?.wait()
    return nil
  }

  func close() {
    lock.withLock { closes += 1 }
    testChanges.signal()
  }
}

final class EmulatorEndpointRegistry: @unchecked Sendable {
  static let shared = EmulatorEndpointRegistry()
  private let lock = NSLock()
  private var probes: [String: EmulatorEndpointProbe] = [:]

  func register(_ probe: EmulatorEndpointProbe, serial: String) {
    lock.withLock { probes[serial] = probe }
  }

  func probe(for serial: String) -> EmulatorEndpointProbe {
    lock.withLock { probes[serial]! }
  }
}

final class AndroidHostClient: @unchecked Sendable {
  private let lock = NSLock()
  private var probe: EmulatorEndpointProbe?

  func previewEndpoint(_ serial: String) async throws -> EmulatorGRPCEndpoint? {
    let probe = EmulatorEndpointRegistry.shared.probe(for: serial)
    lock.withLock { self.probe = probe }
    return await probe.request()
  }

  func close() {
    lock.withLock { probe }?.close()
  }
}
