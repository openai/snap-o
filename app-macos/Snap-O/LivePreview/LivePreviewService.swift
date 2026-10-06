import Foundation
import Observation

@Observable
@MainActor
private final class PreviewConnectionEntry {
  let target: DeviceTarget
  var owner: DevicePreview?
  var error: String?
  @ObservationIgnored var users: Set<UUID> = []
  @ObservationIgnored var startup: Task<Void, Never>?
  @ObservationIgnored var closing: Task<Void, Never>?
  @ObservationIgnored var lease: DeviceCaptureLease?
  @ObservationIgnored var invalidationHandler: UUID?
  init(target: DeviceTarget) { self.target = target }
}

@Observable
@MainActor
private final class PreviewUse {
  struct Request {
    let isInput: Bool
    let cancel: () -> Void
    let finish: () async -> Void
  }
  let id = UUID()
  let entry: PreviewConnectionEntry
  var isClosed = false
  // Prewarm until the window reports its initial visibility.
  var windowVisibility: Bool?
  var isVisible: Bool { windowVisibility == true }
  var isPaneVisible = true
  var wantsClipboard = true
  var viewID: UUID?
  var fileDrop: DeviceFileDrop?
  var emulatorControls: EmulatorControlsController?
  let thumbnail = LivePreviewThumbnail()
  @ObservationIgnored var requests: [UUID: Request] = [:]
  @ObservationIgnored var release: Task<Void, Never>?
  @ObservationIgnored var inputRelease: Task<Void, Never>?
  init(entry: PreviewConnectionEntry) { self.entry = entry }
}

/// Owns one connection per target and grants input to one attachment at a time.
@Observable
@MainActor
final class LivePreviewService {
  private let coordinator: CaptureCoordinator
  private let adb: ADBService
  private let makePreview: (DeviceTarget) -> DevicePreview
  private let makeFileDrop: (Device) -> DeviceFileDrop
  @ObservationIgnored private var entries: [DeviceTarget: PreviewConnectionEntry] = [:]
  @ObservationIgnored private var users: [UUID: PreviewUse] = [:]
  private var inputUser: PreviewUse?
  private var activeID: UUID? { inputUser?.id }
  @ObservationIgnored private var desiredID: UUID?
  @ObservationIgnored private var clipboardOwner: DevicePreview?
  @ObservationIgnored private var focusRevision = 0
  @ObservationIgnored private var focusWork: Task<Void, Never>?
  @ObservationIgnored private var inputCleanup: Task<Void, Never>?
  @ObservationIgnored private var shutdownWork: Task<Void, Never>?
  private var isShuttingDown = false

  init(
    coordinator: CaptureCoordinator, adb: ADBService,
    makeFileDrop: @escaping (Device) -> DeviceFileDrop = { DeviceFileDrop(device: $0) },
    makePreview: @escaping (DeviceTarget) -> DevicePreview
  ) {
    self.coordinator = coordinator
    self.adb = adb
    self.makePreview = makePreview
    self.makeFileDrop = makeFileDrop
  }

  convenience init(coordinator: CaptureCoordinator, adb: ADBService, settings: AppSettings) {
    self.init(coordinator: coordinator, adb: adb) { DevicePreview(target: $0, adb: adb, settings: settings) }
  }

  func attach(
    to device: Device,
    makeEmulatorControls: @MainActor (DeviceTarget) -> EmulatorControlsController? = { _ in nil }
  ) -> LivePreviewAttachment? {
    guard let target = try? device.requireConnection() else { return nil }
    let attachment = attach(to: target)
    guard !attachment.isClosed else { return attachment }
    attachment.user.fileDrop = makeFileDrop(device)
    if EmulatorGRPCEndpoint.isEmulator(target.serial) {
      attachment.user.emulatorControls = makeEmulatorControls(target)
    }
    return attachment
  }

  func attach(to target: DeviceTarget) -> LivePreviewAttachment {
    let entry: PreviewConnectionEntry
    var needsStartup = false
    let previous = entries[target]?.closing
    if let existing = entries[target], existing.closing == nil {
      entry = existing
    } else {
      entry = PreviewConnectionEntry(target: target)
      needsStartup = true
    }
    let user = PreviewUse(entry: entry)
    guard !isShuttingDown, target.isValid else {
      user.isClosed = true
      return LivePreviewAttachment(service: self, user: user)
    }
    entries[target] = entry
    users[user.id] = user
    entry.users.insert(user.id)
    if needsStartup {
      entry.invalidationHandler = try? target.onInvalidation { [weak self, weak entry] in
        Task { @MainActor in
          guard let self, let entry else { return }
          for id in Array(entry.users) { await self.release(id) }
        }
      }
      start(entry, after: previous)
    }
    updateVideoActivity(entry)
    return LivePreviewAttachment(service: self, user: user)
  }

  private func start(_ entry: PreviewConnectionEntry, after previous: Task<Void, Never>?) {
    entry.error = nil
    entry.startup = Task(priority: .userInitiated) {
      await previous?.value
      guard !isShuttingDown, entry.target.isValid, !entry.users.isEmpty else {
        entry.error = "The device connection is no longer available."
        return
      }
      do {
        entry.lease = try coordinator.acquire(target: entry.target, for: .livePreview)
        let owner = makePreview(entry.target)
        entry.owner = owner
        updateVideoActivity(entry)
        owner.start()
        if let desiredID, entry.users.contains(desiredID) { requestFocus(desiredID) }
      } catch {
        entry.error = error.localizedDescription
      }
    }
  }

  fileprivate func retry(_ user: PreviewUse) {
    guard !user.isClosed, user.entry.target.isValid else { return }
    if let owner = user.entry.owner {
      owner.video.retry()
    } else if user.entry.error != nil {
      start(user.entry, after: nil)
    }
  }

  fileprivate func release(_ id: UUID) async {
    guard let user = users[id] else { return }
    if let release = user.release { await release.value; return }
    user.isClosed = true
    if user.entry.users.contains(where: { users[$0]?.isClosed == false }) {
      updateVideoActivity(user.entry)
    }
    user.fileDrop?.cancel()
    let controls = user.emulatorControls?.beginShutdown()
    for request in user.requests.values { request.cancel() }
    if desiredID == id || activeID == id { requestFocus(nil) }
    let focus = user.inputRelease
    let requests = Array(user.requests.values)
    let release = Task {
      async let files: Void = user.fileDrop?.shutdown() ?? ()
      await controls?.value
      await files
      for request in requests { await request.finish() }
      await focus?.value
      let entry = user.entry
      entry.users.remove(id)
      if entry.users.isEmpty { await close(entry) }
      users.removeValue(forKey: id)
    }
    user.release = release
    await release.value
  }

  private func close(_ entry: PreviewConnectionEntry) async {
    if let closing = entry.closing { await closing.value; return }
    if let handler = entry.invalidationHandler {
      entry.target.removeInvalidationHandler(handler)
      entry.invalidationHandler = nil
    }
    let closing = Task {
      await entry.startup?.value
      await entry.owner?.close()
      if let lease = entry.lease { coordinator.release(lease) }
      if entries[entry.target] === entry { entries.removeValue(forKey: entry.target) }
    }
    entry.closing = closing
    await closing.value
  }

  private func updateVideoActivity(_ entry: PreviewConnectionEntry) {
    let active = entry.users.contains { id in
      guard let user = users[id], !user.isClosed else { return false }
      return (user.windowVisibility ?? true) && user.isPaneVisible
    }
    entry.owner?.video.setActive(active)
  }

  fileprivate func setVisible(_ visible: Bool, user: PreviewUse) {
    guard !user.isClosed else { return }
    user.windowVisibility = visible
    updateVideoActivity(user.entry)
    if !visible, desiredID == user.id || activeID == user.id { requestFocus(nil) }
  }

  fileprivate func setPaneVisible(_ visible: Bool, user: PreviewUse) {
    guard !user.isClosed else { return }
    user.isPaneVisible = visible
    updateVideoActivity(user.entry)
    if !visible, desiredID == user.id || activeID == user.id { requestFocus(nil) }
  }

  fileprivate func setFocused(_ focused: Bool, user: PreviewUse) {
    guard !user.isClosed else { return }
    if focused, user.isVisible, user.isPaneVisible {
      requestFocus(user.id)
    } else if desiredID == user.id || activeID == user.id {
      requestFocus(nil)
    }
  }

  fileprivate func setClipboardEnabled(_ enabled: Bool, user: PreviewUse) {
    user.wantsClipboard = enabled
    if activeID == user.id { user.entry.owner?.setClipboardEnabled(enabled) }
  }

  private func requestFocus(_ id: UUID?) {
    guard !isShuttingDown || id == nil else { return }
    if desiredID == id, activeID == id || focusWork != nil { return }
    desiredID = id
    let old = inputUser
    inputUser = nil
    focusRevision += 1
    let revision = focusRevision
    clipboardOwner?.setClipboardEnabled(false)
    if let old {
      let keyboard = old.entry.owner?.keyboard.releaseInput()
      for request in old.requests.values where request.isInput { request.cancel() }
      let cleanup = Task { await finishOldInput(old, keyboard: keyboard) }
      old.inputRelease = cleanup
      inputCleanup = cleanup
    }
    let cleanup = inputCleanup
    let previous = focusWork
    previous?.cancel()
    focusWork = Task {
      defer { if revision == focusRevision { focusWork = nil } }
      await previous?.value
      await cleanup?.value
      guard revision == focusRevision, !Task.isCancelled else { return }
      guard let id, let user = users[id], let owner = await readyOwner(for: user) else {
        if revision == focusRevision {
          await clipboardOwner?.stopClipboard()
          clipboardOwner = nil
        }
        return
      }
      guard revision == focusRevision, !Task.isCancelled, !user.isClosed, user.isVisible, user.isPaneVisible else { return }
      if clipboardOwner !== owner {
        await clipboardOwner?.stopClipboard()
        clipboardOwner = nil
      }
      guard revision == focusRevision, !Task.isCancelled, !user.isClosed else { return }
      inputUser = user
      clipboardOwner = owner
      owner.keyboard.prepare()
      owner.setClipboardEnabled(user.wantsClipboard)
    }
  }

  private func finishOldInput(_ old: PreviewUse, keyboard: Task<Void, Never>?) async {
    for request in Array(old.requests.values) where request.isInput {
      request.cancel()
      await request.finish()
    }
    await old.entry.owner?.pointer.releaseInput(for: old.entry.target)
    await keyboard?.value
  }

  private func readyOwner(for user: PreviewUse) async -> DevicePreview? {
    for await ready in Observations({
      user.isClosed || user.entry.owner != nil || user.entry.error != nil
    }) where ready { break }
    guard !Task.isCancelled, !user.isClosed, let owner = user.entry.owner else { return nil }
    for await ready in Observations({
      owner.preparationFinished || user.isClosed
    }) where ready { break }
    return !Task.isCancelled && !user.isClosed && owner.inputReady ? owner : nil
  }

  fileprivate func acceptsInput(_ user: PreviewUse) -> Bool {
    !user.isClosed && user.isVisible && user.isPaneVisible && user.entry.target.isValid && activeID == user.id
  }

  fileprivate func send(_ event: LivePreviewKeyboardEvent, user: PreviewUse) {
    guard acceptsInput(user) else { return }
    user.entry.owner?.keyboard.send(event)
  }

  fileprivate func sendPointer(_ event: LivePreviewPointerEvent, user: PreviewUse) {
    guard acceptsInput(user), event.target == user.entry.target,
          let owner = user.entry.owner, owner.video.session?.isReady == true else { return }
    let id = UUID()
    let task = Task {
      await owner.pointer.enqueue(event)
      user.requests.removeValue(forKey: id)
    }
    user.requests[id] = PreviewUse.Request(
      isInput: true, cancel: { task.cancel() }, finish: { await task.value }
    )
  }

  fileprivate func request<Value: Sendable>(
    user: PreviewUse, isInput: Bool = false,
    operation: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    guard !user.isClosed, user.entry.target.isValid, !isInput || acceptsInput(user) else { throw CancellationError() }
    let id = UUID()
    let task = Task { try await operation() }
    user.requests[id] = PreviewUse.Request(
      isInput: isInput, cancel: { task.cancel() }, finish: { _ = await task.result }
    )
    defer { user.requests.removeValue(forKey: id) }
    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    guard !user.isClosed, user.entry.target.isValid, !Task.isCancelled else { throw CancellationError() }
    return result
  }

  fileprivate func screenshot(user: PreviewUse) async throws -> Data {
    try await request(user: user) { [adb] in
      try await adb.exec().bound(to: user.entry.target).screencapPNG(deviceID: user.entry.target.serial)
    }
  }

  fileprivate func sendKey(_ key: String, user: PreviewUse) async throws {
    try await request(user: user, isInput: true) { [adb] in
      _ = try await adb.exec().bound(to: user.entry.target).keyEvent(deviceID: user.entry.target.serial, keyCode: key)
    }
  }

  func shutdown() async {
    if let shutdownWork { await shutdownWork.value; return }
    isShuttingDown = true
    requestFocus(nil)
    let ids = Array(users.keys)
    let shutdown = Task {
      await withTaskGroup(of: Void.self) { group in
        for id in ids { group.addTask { await self.release(id) } }
      }
      await focusWork?.value
      await clipboardOwner?.stopClipboard()
      clipboardOwner = nil
    }
    shutdownWork = shutdown
    await shutdown.value
  }
}

/// A window's use of a connection. Release bookkeeping stays in the shared service.
@MainActor
final class LivePreviewAttachment: LivePreviewKeyboardHandling {
  private let service: LivePreviewService
  fileprivate let user: PreviewUse
  var id: UUID { user.id }
  var target: DeviceTarget { user.entry.target }
  var preview: (any PreviewStatus)? { user.isClosed ? nil : user.entry.owner }
  var error: String? {
    if let error = user.entry.error { return error }
    if case .failed(let message) = preview?.videoState { return message }
    return nil
  }
  var isClosed: Bool { user.isClosed }
  var acceptsInput: Bool { service.acceptsInput(user) }
  var fileDrop: DeviceFileDrop? { user.fileDrop }
  var emulatorControls: EmulatorControlsController? { user.emulatorControls }
  var thumbnail: LivePreviewThumbnail { user.thumbnail }
  var isWindowVisible: Bool { user.isVisible }
  var hasFailed: Bool { error != nil }

  func mount(_ viewID: UUID) {
    user.viewID = viewID
  }
  func isMounted(_ viewID: UUID) -> Bool { !isClosed && user.viewID == viewID }

  func updatePresentation(viewID: UUID, visible: Bool, focused: Bool, syncClipboard: Bool) {
    guard user.viewID == viewID, !isClosed else { return }
    setClipboardEnabled(syncClipboard)
    setVisible(visible)
    setFocused(visible && focused)
  }

  func unmount(_ viewID: UUID) {
    guard user.viewID == viewID else { return }
    user.viewID = nil
    setVisible(false)
    user.fileDrop?.cancel()
    user.emulatorControls?.disappear()
  }

  func clearKeyboardError() { user.entry.owner?.keyboard.errorMessage = nil }

  func restartVideo() {
    guard !isClosed else { return }
    user.entry.owner?.video.restart()
  }

  fileprivate init(service: LivePreviewService, user: PreviewUse) {
    self.service = service
    self.user = user
  }

  func renderer(for device: Device, viewID: UUID) -> LivePreviewRenderer? {
    guard !user.isClosed, device.connection == target, let session = user.entry.owner?.video.session else { return nil }
    return LivePreviewRenderer(session: session, device: device) { [weak self] action, source, locations, size in
      guard let self, isMounted(viewID) else { return }
      service.sendPointer(LivePreviewPointerEvent(
        target: target, action: action, source: source, locations: locations, displaySize: size
      ), user: user)
    }
  }

  func setVisible(_ visible: Bool) { service.setVisible(visible, user: user) }
  func setPaneVisible(_ visible: Bool) { service.setPaneVisible(visible, user: user) }
  func setFocused(_ focused: Bool) { service.setFocused(focused, user: user) }
  func setClipboardEnabled(_ enabled: Bool) { service.setClipboardEnabled(enabled, user: user) }
  func send(_ event: LivePreviewKeyboardEvent) { service.send(event, user: user) }
  func prepare() {
    guard acceptsInput else { return }
    user.entry.owner?.keyboard.prepare()
  }

  func discardPendingInput() {
    guard acceptsInput else { return }
    user.entry.owner?.keyboard.discardPendingInput()
  }

  // Leaving the text responder does not deactivate this window's pointer or clipboard.
  func stop() { discardPendingInput() }

  func screenshot() async throws -> Data { try await service.screenshot(user: user) }
  func sendKey(_ key: String) async throws { try await service.sendKey(key, user: user) }

  func retryVideo() { service.retry(user) }

  func rotate(left: Bool) async throws {
    try await service.request(user: user, isInput: true) { [user] in
      guard let owner = user.entry.owner else { throw CancellationError() }
      try await owner.rotation.rotate(left: left)
      if !EmulatorGRPCEndpoint.isEmulator(owner.target.serial) { owner.video.restart() }
    }
  }

  func close() async { await service.release(id) }
}
