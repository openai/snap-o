import AppKit
import Observation

/// Keeps window resources alive across SwiftUI view remounts.
@Observable
@MainActor
final class CaptureWindowSession {
  let controller: CaptureWindowController
  let tools: ToolSession
  private let deviceManager: DeviceManager
  private let historyProtectionID = UUID()
  private(set) var isClosed = false
  private(set) var deviceOpenStatus: String?
  private(set) var deviceOpenSerial: String?
  var deviceOpenError: String?

  @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var pendingCommands: [SnapOCommand] = []
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var closeTask: Task<Void, Never>?
  @ObservationIgnored private var openDeviceTask: Task<Void, Never>?
  @ObservationIgnored private var protectionTask: Task<Void, Never>?
  @ObservationIgnored private var resolvingRequest: DeviceOpenRequest?
  @ObservationIgnored private var history: CaptureHistoryRepository?
  private var showsTools = false

  init(controller: CaptureWindowController, tools: ToolSession, deviceManager: DeviceManager) {
    self.controller = controller
    self.tools = tools
    self.deviceManager = deviceManager
  }

  func attach(to window: NSWindow) {
    guard !isClosed else { return }
    if windowObservers.isEmpty {
      let center = NotificationCenter.default
      windowObservers = [
        center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [self] _ in
          MainActor.assumeIsolated { startIfVisible(window) }
        },
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [self] _ in
          MainActor.assumeIsolated {
            removeWindowObservers()
            // SwiftUI closes and reuses its hidden launch window before showing it.
            if hasStarted { close() }
          }
        }
      ]
    }
    startIfVisible(window)
  }

  private func startIfVisible(_ window: NSWindow) {
    guard window.isVisible, !hasStarted, !isClosed else { return }
    hasStarted = true
    for command in pendingCommands {
      controller.enqueue(command)
    }
    pendingCommands.removeAll()
    startTask = Task { [controller] in
      guard !Task.isCancelled else { return }
      await controller.start()
    }
    updateTools(showsTools)
    resolveRequestedDevice()
  }

  private func removeWindowObservers() {
    for observer in windowObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    windowObservers.removeAll()
  }

  func updateTools(_ visible: Bool) {
    showsTools = visible
    guard !isClosed, hasStarted else { return }
    if visible {
      tools.startIfNeeded()
    } else {
      tools.model?.webContainer?.closeNativeColorPanel()
    }
  }

  func perform(_ command: SnapOCommand) {
    guard !isClosed else { return }
    if hasStarted {
      controller.enqueue(command)
    } else {
      pendingCommands.append(command)
    }
  }

  func openDevice(_ request: DeviceOpenRequest?) {
    guard !isClosed else { return }
    controller.deviceOpenRequest = request
    resolveRequestedDevice()
  }

  func resolveRequestedDevice() {
    guard !isClosed, hasStarted, resolvingRequest != controller.deviceOpenRequest else { return }
    openDeviceTask?.cancel()
    resolvingRequest = controller.deviceOpenRequest
    deviceOpenStatus = nil
    deviceOpenSerial = nil
    guard let request = resolvingRequest else { return }
    deviceOpenError = nil
    openDeviceTask = Task { await resolve(request) }
  }

  func protectCaptures(_ ids: Set<UUID>, in history: CaptureHistoryRepository) {
    guard !isClosed else { return }
    self.history = history
    guard hasStarted else { return }
    protectionTask?.cancel()
    protectionTask = Task { await history.protect(ids, owner: historyProtectionID) }
  }

  @discardableResult
  func close() -> Task<Void, Never> {
    if let closeTask { return closeTask }
    isClosed = true
    removeWindowObservers()
    pendingCommands.removeAll()
    startTask?.cancel()
    openDeviceTask?.cancel()
    protectionTask?.cancel()
    let task = Task {
      await startTask?.value
      await controller.tearDown()
      await tools.stop()
      await openDeviceTask?.value
      await protectionTask?.value
      await history?.protect([], owner: historyProtectionID)
    }
    closeTask = task
    return task
  }

  private func resolve(_ request: DeviceOpenRequest) async {
    defer {
      if !Task.isCancelled, controller.deviceOpenRequest == request {
        deviceOpenStatus = nil
        controller.deviceOpenRequest = nil
        resolvingRequest = nil
      }
    }
    let resolver = DeviceOpenResolver {
      DeviceOpenSnapshot(
        connectedSerials: Set(self.deviceManager.connectedDevices.map(\.id)),
        emulators: self.deviceManager.entries.compactMap {
          guard case .emulator(let device) = $0 else { return nil }
          return device
        },
        hasLoaded: self.deviceManager.hasLoaded,
        isRefreshing: self.deviceManager.isRefreshing || !self.deviceManager.matchingSerials.isEmpty,
        loadError: self.deviceManager.loadError,
        actions: self.deviceManager.actions,
        launchErrors: self.deviceManager.launchErrors
      )
    } start: { device in
      self.deviceManager.start(device)
    }
    do {
      let serial = try await resolver.resolve(request) { self.deviceOpenStatus = $0 }
      try Task.checkCancellation()
      guard controller.deviceOpenRequest == request, !isClosed else { return }
      deviceOpenSerial = serial
      deviceOpenStatus = "Opening"
      await controller.showLivePreview(deviceID: serial)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, controller.deviceOpenRequest == request, !isClosed else { return }
      deviceOpenError = error.localizedDescription
    }
  }
}
