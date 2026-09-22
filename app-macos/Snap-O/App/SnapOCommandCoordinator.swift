import AppKit
import SwiftUI

@MainActor
private protocol SnapOCommandTarget: AnyObject {
  func perform(_ command: SnapOCommand)
  func showLivePreview(deviceID: String, focus: Bool) -> Bool
  func isLivePreviewSelected(deviceID: String) -> Bool
  func liveThumbnail(deviceID: String) -> LivePreviewThumbnail?
}

@MainActor
final class SnapOCommandCoordinator {
  static let shared = SnapOCommandCoordinator()

  private let targets = NSHashTable<AnyObject>.weakObjects()
  private weak var focusedTarget: (any SnapOCommandTarget)?
  private weak var lastTarget: (any SnapOCommandTarget)?
  private var pendingPreviewDeviceID: String?
  private var pendingCommands: [SnapOCommand] = []

  private init() {}

  func handle(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "snapo" else { return false }
    guard let command = SnapOCommand.from(url: url) else { return false }
    if let focusedTarget {
      focusedTarget.perform(command)
    } else {
      pendingCommands.append(command)
    }
    return true
  }

  @discardableResult
  func showLivePreview(deviceID: String) -> Bool {
    guard let target = focusedTarget ?? lastTarget else {
      pendingPreviewDeviceID = deviceID
      return false
    }
    return target.showLivePreview(deviceID: deviceID, focus: true)
  }

  func selectLivePreview(deviceID: String) -> LivePreviewRequest? {
    guard let target = focusedTarget ?? lastTarget,
          target.showLivePreview(deviceID: deviceID, focus: false) else { return nil }
    return LivePreviewRequest { [weak target] in
      guard let target, target.isLivePreviewSelected(deviceID: deviceID) else { return .inactive }
      return target.liveThumbnail(deviceID: deviceID)?.videoRenderer?.displayedPixelBuffer() == nil ? .waiting : .ready
    }
  }

  func liveThumbnail(deviceID: String) -> LivePreviewThumbnail? {
    for case let target as any SnapOCommandTarget in targets.allObjects {
      if let thumbnail = target.liveThumbnail(deviceID: deviceID), thumbnail.videoRenderer != nil {
        return thumbnail
      }
    }
    return nil
  }

  fileprivate func remove(_ target: any SnapOCommandTarget) {
    targets.remove(target)
    deactivate(target)
    if lastTarget === target { lastTarget = nil }
  }

  fileprivate func activate(_ target: any SnapOCommandTarget) {
    targets.add(target)
    focusedTarget = target
    lastTarget = target
    if let deviceID = pendingPreviewDeviceID {
      pendingPreviewDeviceID = nil
      _ = target.showLivePreview(deviceID: deviceID, focus: true)
    }
    let commands = pendingCommands
    pendingCommands.removeAll()
    for command in commands {
      target.perform(command)
    }
  }

  fileprivate func deactivate(_ target: any SnapOCommandTarget) {
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
  let preview: @MainActor (String, Bool) -> Bool
  let previewIsSelected: @MainActor (String) -> Bool
  let thumbnail: @MainActor (String) -> LivePreviewThumbnail?

  func makeNSView(context: Context) -> WindowCommandTargetView {
    WindowCommandTargetView(perform: perform, preview: preview, previewIsSelected: previewIsSelected, thumbnail: thumbnail)
  }

  func updateNSView(_ nsView: WindowCommandTargetView, context: Context) {
    nsView.performCommand = perform
    nsView.previewDevice = preview
    nsView.previewIsSelected = previewIsSelected
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
  var previewDevice: @MainActor (String, Bool) -> Bool
  var previewIsSelected: @MainActor (String) -> Bool
  var thumbnailForDevice: @MainActor (String) -> LivePreviewThumbnail?

  private weak var observedWindow: NSWindow?
  private var notificationTokens: [NSObjectProtocol] = []

  init(
    perform: @escaping @MainActor (SnapOCommand) -> Void,
    preview: @escaping @MainActor (String, Bool) -> Bool,
    previewIsSelected: @escaping @MainActor (String) -> Bool,
    thumbnail: @escaping @MainActor (String) -> LivePreviewThumbnail?
  ) {
    performCommand = perform
    previewDevice = preview
    self.previewIsSelected = previewIsSelected
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

  func showLivePreview(deviceID: String, focus: Bool) -> Bool {
    // A hidden window cannot start rendering until it becomes visible.
    guard focus || window?.occlusionState.contains(.visible) == true else { return false }
    if focus { window?.makeKeyAndOrderFront(nil) }
    return previewDevice(deviceID, focus)
  }

  func liveThumbnail(deviceID: String) -> LivePreviewThumbnail? {
    thumbnailForDevice(deviceID)
  }

  func isLivePreviewSelected(deviceID: String) -> Bool {
    observedWindow != nil && window?.occlusionState.contains(.visible) == true && previewIsSelected(deviceID)
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
