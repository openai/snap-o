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
      stream = DeviceVideoStream(source: makeSource(target), previous: previous, scalesFrames: target.isLocalEmulator)
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
  private var frameSize = LivePreviewFrameSize.native

  init(target: DeviceTarget, hub: DeviceVideoHub = .shared, replaysLastFrame: Bool = true) {
    self.target = target
    self.hub = hub
    self.replaysLastFrame = replaysLastFrame
  }

  func start(deliver: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void) {
    guard subscription == nil, !hasStopped else { return }
    let subscription = hub.subscription(target: target)
    self.subscription = subscription
    subscription.stream.subscribe(subscription.id, frameSize: frameSize, replaysLastFrame: replaysLastFrame, receive: deliver)
  }

  func setFrameSize(_ size: LivePreviewFrameSize) {
    frameSize = size
    if let subscription { subscription.stream.setFrameSize(size, for: subscription.id) }
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
    var frameSize: LivePreviewFrameSize
  }

  private let source: any LivePreviewFrameSource
  private let scalesFrames: Bool
  private var frameSize = LivePreviewFrameSize.inactive
  private var previous: DeviceVideoStream?
  private var startup: Task<Void, Never>?
  private var hasStarted = false
  private(set) var hasStopped = false
  private var subscribers: [UUID: Subscriber] = [:]
  private var formatEvent: LivePreviewFrameEvent?
  private var density: CGFloat?
  private var latestIndependentFrame: CMSampleBuffer?

  var isEmpty: Bool {
    subscribers.isEmpty
  }

  var hasIndependentFrames: Bool {
    source.hasIndependentFrames
  }

  init(source: any LivePreviewFrameSource, previous: DeviceVideoStream?, scalesFrames: Bool) {
    self.source = source
    self.scalesFrames = scalesFrames
    self.previous = previous
    if scalesFrames { source.setFrameSize(.inactive) }
  }

  func subscribe(
    _ id: UUID, frameSize: LivePreviewFrameSize, replaysLastFrame: Bool,
    receive: @escaping @MainActor @Sendable (LivePreviewFrameEvent) -> Void
  ) {
    subscribers[id] = Subscriber(receive: receive, frameSize: frameSize)
    updateFrameSize()
    if let density { receive(.density(density)) }
    guard subscribers[id] != nil, !hasStopped else { return }
    if let formatEvent { receive(formatEvent) }
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

  func setFrameSize(_ size: LivePreviewFrameSize, for id: UUID) {
    guard subscribers[id] != nil, !hasStopped else { return }
    subscribers[id]?.frameSize = size
    updateFrameSize()
  }

  private func updateFrameSize() {
    guard scalesFrames else { return }
    let size = LivePreviewFrameSize.maximum(subscribers.values.lazy.map(\.frameSize))
    guard size != frameSize else { return }
    frameSize = size
    // A recorder joining a scaled preview must wait for the new native format.
    formatEvent = nil
    latestIndependentFrame = nil
    source.setFrameSize(size)
  }

  func unsubscribe(_ id: UUID) {
    subscribers.removeValue(forKey: id)
    updateFrameSize()
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
    case .format:
      formatEvent = event
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
