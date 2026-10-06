import AppKit
import SwiftUI

@MainActor
protocol SnapOCommandTarget: AnyObject {
  func perform(_ command: SnapOCommand)
  func openDevice(_ request: DeviceOpenRequest)
  func liveThumbnail(for connection: DeviceTarget) -> LivePreviewThumbnail?
}

@MainActor
final class SnapOCommandCoordinator {
  static let shared = SnapOCommandCoordinator()

  private let targets = NSHashTable<AnyObject>.weakObjects()
  private weak var focusedTarget: (any SnapOCommandTarget)?
  private weak var lastTarget: (any SnapOCommandTarget)?
  private var pendingDeviceRequest: DeviceOpenRequest?
  private var isOpeningWorkspace = false
  var openWorkspace: (() -> Void)?
  private var pendingCommands: [SnapOCommand] = []

  init() {}

  func handle(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "snapo" else { return false }
    if url.host?.lowercased() == "open" {
      guard let request = DeviceOpenRequest(url: url) else { return false }
      openDevice(request)
      return true
    }
    guard let command = SnapOCommand.from(url: url) else { return false }
    if let target = focusedTarget ?? lastTarget ?? targets.allObjects.first as? any SnapOCommandTarget {
      target.perform(command)
    } else {
      pendingCommands.append(command)
    }
    return true
  }

  func openDevice(_ request: DeviceOpenRequest) {
    if let target = focusedTarget ?? lastTarget ?? targets.allObjects.first as? any SnapOCommandTarget {
      target.openDevice(request)
    } else {
      pendingDeviceRequest = request
      if !isOpeningWorkspace, let openWorkspace {
        isOpeningWorkspace = true
        openWorkspace()
      }
    }
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
    deliverPending(to: target)
  }

  private func deliverPending(to target: any SnapOCommandTarget) {
    isOpeningWorkspace = false
    if let request = pendingDeviceRequest {
      pendingDeviceRequest = nil
      target.openDevice(request)
    }
    let commands = pendingCommands
    pendingCommands.removeAll()
    for command in commands {
      target.perform(command)
    }
  }

  func deactivate(_ target: any SnapOCommandTarget) {
    guard focusedTarget === target else { return }
    focusedTarget = nil
  }
}

extension SnapOCommand {
  static func from(url: URL) -> SnapOCommand? {
    let host = url.host?.lowercased() ?? ""
    let pathComponent = url.pathComponents.dropFirst().first?.lowercased() ?? ""
    let token = host.isEmpty ? pathComponent : host
    return SnapOCommand(rawValue: token)
  }
}

struct WindowCommandRegistration: NSViewRepresentable {
  let perform: @MainActor (SnapOCommand) -> Void
  let openDevice: @MainActor (DeviceOpenRequest) -> Void
  var attached: @MainActor (NSWindow) -> Void = { _ in }
  let thumbnail: @MainActor (DeviceTarget) -> LivePreviewThumbnail?

  func makeNSView(context: Context) -> WindowCommandTargetView {
    WindowCommandTargetView(perform: perform, openDevice: openDevice, attached: attached, thumbnail: thumbnail)
  }

  func updateNSView(_ nsView: WindowCommandTargetView, context: Context) {
    nsView.performCommand = perform
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
  var performCommand: @MainActor (SnapOCommand) -> Void
  var openDeviceRequest: @MainActor (DeviceOpenRequest) -> Void
  var onAttached: @MainActor (NSWindow) -> Void
  var thumbnailForDevice: @MainActor (DeviceTarget) -> LivePreviewThumbnail?

  private weak var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  init(
    perform: @escaping @MainActor (SnapOCommand) -> Void,
    openDevice: @escaping @MainActor (DeviceOpenRequest) -> Void,
    attached: @escaping @MainActor (NSWindow) -> Void = { _ in },
    thumbnail: @escaping @MainActor (DeviceTarget) -> LivePreviewThumbnail?
  ) {
    performCommand = perform
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

  func perform(_ command: SnapOCommand) {
    performCommand(command)
  }

  func openDevice(_ request: DeviceOpenRequest) {
    // Let SwiftUI finish creating a hidden launch window before requesting focus.
    if let window, window.isVisible || window.isMiniaturized {
      NSApplication.shared.activate(ignoringOtherApps: true)
      window.deminiaturize(nil)
      window.makeKeyAndOrderFront(nil)
    }
    openDeviceRequest(request)
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
