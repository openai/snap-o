@preconcurrency import AVFoundation
import Foundation

/// Shares one video source per connection across preview renderers and recorders.
@MainActor
final class DeviceVideoHub {
  static let shared = DeviceVideoHub()
  fileprivate struct Subscription {
    let target: DeviceTarget
    let stream: DeviceVideoStream
    let id: UUID
  }

  private let makeSource: (DeviceTarget) -> any LivePreviewFrameSource
  private var sessions: [DeviceTarget: DeviceVideoStream] = [:]

  init(makeSource: @escaping (DeviceTarget) -> any LivePreviewFrameSource = { target in
    if target.isLocalEmulator {
      EmulatorPreviewFrameSource(target: target)
    } else {
      DeviceVideoConnection(target: target)
    }
  }) {
    self.makeSource = makeSource
  }

  fileprivate func subscription(target: DeviceTarget) -> Subscription {
    let stream: DeviceVideoStream
    if let existing = sessions[target], !existing.hasStopped {
      stream = existing
    } else {
      let previous = sessions[target]
      previous?.stop()
      stream = DeviceVideoStream(source: makeSource(target), previous: previous)
      sessions[target] = stream
    }
    return Subscription(target: target, stream: stream, id: UUID())
  }

  fileprivate func unsubscribe(_ subscription: Subscription) -> Task<Void, Never>? {
    let stream = subscription.stream
    stream.unsubscribe(subscription.id)
    guard stream.isEmpty else { return nil }
    stream.stop()
    return Task {
      await stream.waitUntilStopped()
      if sessions[subscription.target] === stream {
        sessions.removeValue(forKey: subscription.target)
      }
    }
  }
}

@MainActor
final class DeviceVideoSource: LivePreviewFrameSource {
  var hasIndependentFrames: Bool {
    subscription?.stream.hasIndependentFrames ?? false
  }

  private let target: DeviceTarget
  private let hub: DeviceVideoHub
  private let replaysLastFrame: Bool
  private var subscription: DeviceVideoHub.Subscription?
  private var cleanup: Task<Void, Never>?
  private var hasStopped = false

  init(target: DeviceTarget, hub: DeviceVideoHub = .shared, replaysLastFrame: Bool = true) {
    self.target = target
    self.hub = hub
    self.replaysLastFrame = replaysLastFrame
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    guard subscription == nil, !hasStopped else { return }
    let subscription = hub.subscription(target: target)
    self.subscription = subscription
    subscription.stream.subscribe(subscription.id, replaysLastFrame: replaysLastFrame, receive: deliver)
  }

  func requestKeyFrame() {
    subscription?.stream.requestKeyFrame()
  }

  func stop() {
    guard !hasStopped else { return }
    hasStopped = true
    if let subscription { cleanup = hub.unsubscribe(subscription) }
    subscription = nil
  }

  func waitUntilStopped() async {
    await cleanup?.value
  }
}

/// Keeps subscriber state separate from the device transport.
@MainActor
private final class DeviceVideoStream {
  private struct Subscriber {
    let receive: @MainActor @Sendable (LivePreviewFrameEvent) -> Void
    var needsKeyFrame = true
  }

  private let source: any LivePreviewFrameSource
  private var previous: DeviceVideoStream?
  private var startup: Task<Void, Never>?
  private var hasStarted = false
  private(set) var hasStopped = false
  private var subscribers: [UUID: Subscriber] = [:]
  private var format: CMVideoFormatDescription?
  private var density: CGFloat?
  private var latestIndependentFrame: CMSampleBuffer?

  var isEmpty: Bool {
    subscribers.isEmpty
  }

  var hasIndependentFrames: Bool {
    source.hasIndependentFrames
  }

  init(source: any LivePreviewFrameSource, previous: DeviceVideoStream?) {
    self.source = source
    self.previous = previous
  }

  func subscribe(_ id: UUID, replaysLastFrame: Bool, receive: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    subscribers[id] = Subscriber(receive: receive)
    if let density { receive(.density(density)) }
    guard subscribers[id] != nil, !hasStopped else { return }
    if let format { receive(.format(format)) }
    guard subscribers[id] != nil, !hasStopped else { return }
    if replaysLastFrame, let latestIndependentFrame {
      subscribers[id]?.needsKeyFrame = false
      receive(.sample(latestIndependentFrame, isKeyFrame: true))
    }
    guard subscribers[id] != nil, !hasStopped else { return }
    if hasStarted {
      source.requestKeyFrame()
    } else if startup == nil {
      if let previous {
        self.previous = nil
        startup = Task {
          await previous.waitUntilStopped()
          guard !hasStopped else { return }
          start()
        }
      } else {
        start()
      }
    }
  }

  func requestKeyFrame() {
    guard !hasStopped else { return }
    source.requestKeyFrame()
  }

  func unsubscribe(_ id: UUID) {
    subscribers.removeValue(forKey: id)
  }

  func stop() {
    guard !hasStopped else { return }
    hasStopped = true
    startup?.cancel()
    latestIndependentFrame = nil
    source.stop()
  }

  func waitUntilStopped() async {
    await startup?.value
    await source.waitUntilStopped()
  }

  private func start() {
    hasStarted = true
    source.start { [weak self] event in self?.receive(event) }
  }

  private func receive(_ event: LivePreviewFrameEvent) {
    guard !hasStopped else { return }
    switch event {
    case .density(let density):
      self.density = density
    case .format(let description):
      format = description
      latestIndependentFrame = nil
      for id in subscribers.keys {
        subscribers[id]?.needsKeyFrame = true
      }
    case .sample(let sample, let keyFrame):
      if hasIndependentFrames { latestIndependentFrame = sample }
      for id in subscribers.keys where keyFrame {
        subscribers[id]?.needsKeyFrame = false
      }
    case .stopped:
      stop()
    }
    for (id, subscriber) in Array(subscribers) {
      guard subscribers[id] != nil else { continue }
      if case .sample = event, subscriber.needsKeyFrame { continue }
      subscriber.receive(event)
    }
  }
}
