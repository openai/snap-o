import Foundation

public enum PerfKey: String, Hashable {
  case appFirstSnapshot
  case captureRequest
  case recordingStart
  case recordingRender
  case livePreviewStart
}

#if PERF_TRACING

private struct PerfStep {
  let label: String
  let at: Date
  let sinceStart: TimeInterval
  let sincePrevious: TimeInterval
}

private struct PerfTraceRecord {
  let name: String
  let startedAt: Date
  var lastAt: Date
  var steps: [PerfStep] = []
}

@usableFromInline
final class PerfStore: @unchecked Sendable {
  @usableFromInline static let shared = PerfStore()
  private var lock = NSLock()
  private var traces: [PerfKey: PerfTraceRecord] = [:]

  @usableFromInline
  func start(_ key: PerfKey, name: String) {
    lock.lock()
    defer { lock.unlock() }
    if traces[key] == nil {
      let now = Date()
      traces[key] = PerfTraceRecord(name: name, startedAt: now, lastAt: now, steps: [])
      SnapOLog.perf.log("[start] \(name)")
    }
  }

  @usableFromInline
  func startIfNeeded(_ key: PerfKey, name: String) {
    lock.lock()
    defer { lock.unlock() }
    if traces[key] == nil {
      let now = Date()
      traces[key] = PerfTraceRecord(name: name, startedAt: now, lastAt: now, steps: [])
      SnapOLog.perf.log("[start] \(name)")
    }
  }

  @usableFromInline
  func step(_ key: PerfKey, _ label: String) {
    lock.lock()
    defer { lock.unlock() }
    guard var trace = traces[key] else { return }
    let now = Date()
    let step = PerfStep(
      label: label,
      at: now,
      sinceStart: now.timeIntervalSince(trace.startedAt),
      sincePrevious: now.timeIntervalSince(trace.lastAt)
    )
    trace.steps.append(step)
    trace.lastAt = now
    traces[key] = trace

    let incUs = Int((step.sincePrevious * 1_000_000).rounded())
    let totalUs = Int((step.sinceStart * 1_000_000).rounded())
    SnapOLog.perf.log("[step] \(trace.name) :: \(label) :: +\(incUs)us (total \(totalUs)us)")
  }

  @usableFromInline
  func end(_ key: PerfKey, finalLabel: String? = nil) {
    let trace: PerfTraceRecord?
    let total: TimeInterval
    do {
      lock.lock()
      defer { lock.unlock() }
      guard let existing = traces.removeValue(forKey: key) else { return }
      trace = existing
      total = Date().timeIntervalSince(existing.startedAt)
    }

    guard let trace else { return }
    let totalUs = Int((total * 1000 * 1000).rounded())
    if let final = finalLabel {
      SnapOLog.perf.log("[end] \(trace.name) :: \(final) :: total \(totalUs)us")
    } else {
      SnapOLog.perf.log("[end] \(trace.name) :: total \(totalUs)us")
    }
    if !trace.steps.isEmpty {
      let parts = trace.steps.map { step in
        let us = Int((step.sincePrevious * 1_000_000).rounded())
        return "\(step.label): +\(us)us"
      }
      let summary = parts.joined(separator: ", ")
      SnapOLog.perf.log("[summary] \(trace.name) :: \(summary) :: total \(totalUs)us")
    }
  }
}

public enum Perf {
  @inlinable
  public static func start(_ key: PerfKey, name: String) {
    PerfStore.shared.start(key, name: name)
  }

  @inlinable
  public static func startIfNeeded(_ key: PerfKey, name: String) {
    PerfStore.shared.startIfNeeded(key, name: name)
  }

  @inlinable
  public static func step(_ key: PerfKey, _ label: String) {
    PerfStore.shared.step(key, label)
  }

  @inlinable
  public static func end(_ key: PerfKey, finalLabel: String? = nil) {
    PerfStore.shared.end(key, finalLabel: finalLabel)
  }
}

#else

public enum Perf {
  @inlinable
  public static func start(_ key: PerfKey, name: String) {}
  @inlinable
  public static func startIfNeeded(_ key: PerfKey, name: String) {}
  @inlinable
  public static func step(_ key: PerfKey, _ label: String) {}
  @inlinable
  public static func end(_ key: PerfKey, finalLabel: String? = nil) {}
}

#endif
