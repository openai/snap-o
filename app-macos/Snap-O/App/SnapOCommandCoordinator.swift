import AppKit
import SwiftUI

@MainActor
protocol SnapOCommandTarget: AnyObject {
  func showWindow() -> Bool
  func showLivePreview()
  func openDevice(_ request: DeviceOpenRequest)
  func liveThumbnail(for connection: DeviceTarget) -> LivePreviewThumbnail?
}

@MainActor
final class SnapOCommandCoordinator {
  static let shared = SnapOCommandCoordinator()

  private let targets = NSHashTable<AnyObject>.weakObjects()
  private weak var focusedTarget: (any SnapOCommandTarget)?
  private weak var lastTarget: (any SnapOCommandTarget)?
  private var currentTarget: (any SnapOCommandTarget)? {
    focusedTarget ?? lastTarget ?? targets.allObjects.first as? any SnapOCommandTarget
  }

  private var pendingDeviceRequest: DeviceOpenRequest?
  private var workspaceActivation: CheckedContinuation<Void, Never>?
  private var isOpeningWorkspace = false
  var openWorkspace: (() -> Void)? {
    didSet { openWorkspaceIfNeeded() }
  }

  private var pendingLivePreview = false

  var requiresDeviceLinkApproval: (DeviceOpenRequest) -> Bool = { _ in true }
  var authorizeDeviceLink: ((DeviceOpenRequest) async -> DeviceOpenRequest?)?
  private(set) var deviceLinkTask: Task<Void, Never>?

  init() {}

  func handle(url: URL) -> Bool {
    guard let link = DeviceOpenURL(url: url) else { return false }
    guard deviceLinkTask == nil else { return true }
    switch link {
    case .target(let request):
      if let authorizeDeviceLink, requiresDeviceLinkApproval(request) {
        deviceLinkTask = Task {
          await prepareWorkspaceForApproval()
          let approved = await authorizeDeviceLink(request)
          self.deviceLinkTask = nil
          if let approved { self.openDevice(approved) }
        }
      } else {
        openDevice(request)
      }
    case .currentPreview:
      if let target = currentTarget {
        target.showLivePreview()
      } else {
        pendingLivePreview = true
        openWorkspaceIfNeeded()
      }
    }
    return true
  }

  func openDevice(_ request: DeviceOpenRequest) {
    guard deviceLinkTask == nil else { return }
    if let target = currentTarget {
      target.openDevice(request)
    } else {
      pendingDeviceRequest = request
      openWorkspaceIfNeeded()
    }
  }

  private func prepareWorkspaceForApproval() async {
    if currentTarget?.showWindow() == true { return }
    // SwiftUI can register a hidden launch window. Wait for a workspace to become key
    // so the review dialogs have a parent when the first alert closes.
    await withCheckedContinuation {
      workspaceActivation = $0
      openWorkspaceIfNeeded()
    }
  }

  private func openWorkspaceIfNeeded() {
    guard pendingDeviceRequest != nil || pendingLivePreview || workspaceActivation != nil,
          !isOpeningWorkspace, let openWorkspace else { return }
    isOpeningWorkspace = true
    openWorkspace()
  }

  func liveThumbnail(for connection: DeviceTarget) -> LivePreviewThumbnail? {
    guard connection.isValid else { return nil }
    for case let target as any SnapOCommandTarget in targets.allObjects {
      if let thumbnail = target.liveThumbnail(for: connection), thumbnail.videoRenderer != nil {
        return thumbnail
      }
    }
    return nil
  }

  func remove(_ target: any SnapOCommandTarget) {
    targets.remove(target)
    deactivate(target)
    if lastTarget === target { lastTarget = nil }
  }

  func register(_ target: any SnapOCommandTarget) {
    targets.add(target)
    if lastTarget == nil { lastTarget = target }
    deliverPending(to: focusedTarget ?? lastTarget ?? target)
  }

  func activate(_ target: any SnapOCommandTarget) {
    targets.add(target)
    focusedTarget = target
    lastTarget = target
    workspaceActivation?.resume()
    workspaceActivation = nil
    deliverPending(to: target)
  }

  private func deliverPending(to target: any SnapOCommandTarget) {
    if workspaceActivation == nil { isOpeningWorkspace = false }
    if let request = pendingDeviceRequest {
      pendingDeviceRequest = nil
      target.openDevice(request)
    }
    if pendingLivePreview {
      pendingLivePreview = false
      target.showLivePreview()
    }
  }

  func deactivate(_ target: any SnapOCommandTarget) {
    guard focusedTarget === target else { return }
    focusedTarget = nil
  }
}

struct WindowCommandRegistration: NSViewRepresentable {
  let showLivePreview: @MainActor () -> Void
  let openDevice: @MainActor (DeviceOpenRequest) -> Void
  var attached: @MainActor (NSWindow) -> Void = { _ in }
  let thumbnail: @MainActor (DeviceTarget) -> LivePreviewThumbnail?

  func makeNSView(context: Context) -> WindowCommandTargetView {
    WindowCommandTargetView(showLivePreview: showLivePreview, openDevice: openDevice, attached: attached, thumbnail: thumbnail)
  }

  func updateNSView(_ nsView: WindowCommandTargetView, context: Context) {
    nsView.showLivePreviewAction = showLivePreview
    nsView.openDeviceRequest = openDevice
    nsView.onAttached = attached
    nsView.thumbnailForDevice = thumbnail
    nsView.attach(to: nsView.window)
  }

  static func dismantleNSView(_ nsView: WindowCommandTargetView, coordinator: ()) {
    nsView.detach()
  }
}

@MainActor
final class WindowCommandTargetView: NSView, SnapOCommandTarget {
  var showLivePreviewAction: @MainActor () -> Void
  var openDeviceRequest: @MainActor (DeviceOpenRequest) -> Void
  var onAttached: @MainActor (NSWindow) -> Void
  var thumbnailForDevice: @MainActor (DeviceTarget) -> LivePreviewThumbnail?

  private weak var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  init(
    showLivePreview: @escaping @MainActor () -> Void,
    openDevice: @escaping @MainActor (DeviceOpenRequest) -> Void,
    attached: @escaping @MainActor (NSWindow) -> Void = { _ in },
    thumbnail: @escaping @MainActor (DeviceTarget) -> LivePreviewThumbnail?
  ) {
    showLivePreviewAction = showLivePreview
    openDeviceRequest = openDevice
    onAttached = attached
    thumbnailForDevice = thumbnail
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attach(to: window)
  }

  func showLivePreview() {
    showWindow()
    showLivePreviewAction()
  }

  func openDevice(_ request: DeviceOpenRequest) {
    showWindow()
    openDeviceRequest(request)
  }

  @discardableResult
  func showWindow() -> Bool {
    // Let SwiftUI finish creating a hidden launch window before requesting focus.
    guard let window, window.isVisible || window.isMiniaturized else { return false }
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.deminiaturize(nil)
    window.makeKeyAndOrderFront(nil)
    return true
  }

  func liveThumbnail(for connection: DeviceTarget) -> LivePreviewThumbnail? {
    thumbnailForDevice(connection)
  }

  func attach(to window: NSWindow?) {
    guard observedWindow !== window else {
      if window?.isKeyWindow == true {
        SnapOCommandCoordinator.shared.activate(self)
      }
      return
    }

    detach()
    guard let window else { return }
    observedWindow = window
    onAttached(window)
    SnapOCommandCoordinator.shared.register(self)

    let center = NotificationCenter.default
    notificationTokens = [
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated {
          SnapOCommandCoordinator.shared.activate(self)
        }
      },
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated {
          SnapOCommandCoordinator.shared.deactivate(self)
        }
      },
      center.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        MainActor.assumeIsolated {
          self.detach()
        }
      }
    ]

    if window.isKeyWindow {
      SnapOCommandCoordinator.shared.activate(self)
    }
  }

  func detach() {
    SnapOCommandCoordinator.shared.remove(self)
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
    notificationTokens.removeAll()
    observedWindow = nil
  }
}
