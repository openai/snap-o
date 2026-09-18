import AppKit

/// Observes command routing without validating menus or changing focus.
@MainActor
final class CommandDiagnostics {
  static let shared = CommandDiagnostics()

  private var keyMonitor: Any?
  private var notificationTokens: [NSObjectProtocol] = []
  private weak var focusedWorkspace: WorkspaceLayoutController?
  private var lastFocusedWorkspaceState: String?
  private var shortcutSequence = 0
  private var recordSequence = 0
  private let session = UUID().uuidString
  private var history = CommandDiagnosticHistory()

  private init() {}

  func start() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        self?.received(event)
      }
      return event
    }

    let names: [Notification.Name] = [
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
      NSApplication.willTerminateNotification,
      NSMenu.didBeginTrackingNotification,
      NSMenu.didEndTrackingNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didResignMainNotification,
      NSWindow.willCloseNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification
    ]
    notificationTokens = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let window = notification.object as? NSWindow
        MainActor.assumeIsolated {
          if name == NSApplication.willTerminateNotification {
            self?.record("application-will-terminate")
            return
          }
          guard window?.canBecomeKey != false else { return }
          self?.remember(
            "notification=\(name.rawValue) window=\(Self.windowState(window))"
              + " active=\(NSApp.isActive) key=\(NSApp.keyWindow?.windowNumber ?? -1)"
          )
        }
      }
    }

    for name in [NSMenu.willSendActionNotification, NSMenu.didSendActionNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(menuActionSent(_:)), name: name, object: nil)
    }

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let system = ProcessInfo.processInfo.operatingSystemVersionString
    record("diagnostics-start version=\(version) build=\(build) system=\(system) schema=2")
  }

  func focusedWorkspaceEvaluated(_ workspace: WorkspaceLayoutController?) {
    focusedWorkspace = workspace
    let state = Self.workspaceState(workspace)
    guard state != lastFocusedWorkspaceState else { return }
    lastFocusedWorkspaceState = state
    remember("focused-workspace-evaluated \(state)")
  }

  func paneAction(_ action: String, source: String, workspace: WorkspaceLayoutController?) {
    guard !Self.isRepeatingKeyEvent else { return }
    record("pane-action=\(action) source=\(source) workspace=\(Self.workspaceState(workspace))")
  }

  func replacingDelegate(of window: NSWindow, with replacement: any NSWindowDelegate) {
    record(
      "replace-window-delegate window=\(Self.windowState(window)) replacement=\(Self.className(replacement))"
    )
  }

  func record(_ reason: String) {
    recordSequence += 1
    let sequence = recordSequence
    let now = ProcessInfo.processInfo.systemUptime
    let recent = history.drain()
    if recent.droppedCount > 0 {
      SnapOLog.commands.notice(
        "session=\(self.session, privacy: .public) event=\(sequence) older-context-dropped=\(recent.droppedCount)"
      )
    }
    for entry in recent.entries {
      let age = Int(max(0, now - entry.uptime) * 1000)
      SnapOLog.commands.notice(
        "session=\(self.session, privacy: .public) event=\(sequence) context-age-ms=\(age) \(entry.message, privacy: .public)"
      )
    }
    // Persist in release builds. Split context to stay below unified logging's per-string limit.
    SnapOLog.commands.notice("session=\(self.session, privacy: .public) event=\(sequence) \(reason, privacy: .public)")
    SnapOLog.commands.notice("session=\(self.session, privacy: .public) event=\(sequence) focus \(self.focusState(), privacy: .public)")
    SnapOLog.commands.notice(
      "session=\(self.session, privacy: .public) event=\(sequence) menu \(Self.menuState(NSApp.mainMenu), privacy: .public)"
    )
  }

  private func remember(_ message: String) {
    history.append(message, uptime: ProcessInfo.processInfo.systemUptime)
  }

  private static var isRepeatingKeyEvent: Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
    return event.isARepeat
  }

  // AppKit sends menu actions on the main thread.
  @objc
  private func menuActionSent(_ notification: Notification) {
    guard !Self.isRepeatingKeyEvent,
          let item = notification.userInfo?["MenuItem"] as? NSMenuItem,
          Self.isObservedMenuItem(item) else { return }
    record("menu-action=\(notification.name.rawValue) item=\(Self.menuItemState(item))")
  }

  private func received(_ event: NSEvent) {
    guard !event.isARepeat, let shortcut = Self.shortcutName(for: event) else { return }
    shortcutSequence += 1
    let sequence = shortcutSequence
    record(
      "shortcut-received seq=\(sequence) shortcut=\(shortcut) keyCode=\(event.keyCode)"
        + " modifiers=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat) eventWindow=\(event.windowNumber)"
    )
    // Sample the next main-queue turn without forcing menu validation, which could repair the failure.
    DispatchQueue.main.async { [weak self] in
      self?.record("shortcut-next-main-turn seq=\(sequence) shortcut=\(shortcut)")
    }
  }

  private static func shortcutName(for event: NSEvent) -> String? {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers == .command || modifiers == [.command, .option] else { return nil }
    let key = event.charactersIgnoringModifiers?.lowercased()
    // Include physical keys so a changed keyboard layout is visible without logging typed text.
    if modifiers == .command, key == "q" || event.keyCode == 12 { return "command-q" }
    if modifiers == [.command, .option] {
      if key == "c" || event.keyCode == 8 { return "command-option-c" }
      if key == "i" || event.keyCode == 34 { return "command-option-i" }
    }
    return nil
  }

  private func focusState() -> String {
    let app = NSApplication.shared
    return "active=\(app.isActive) key=\(Self.windowState(app.keyWindow))"
      + " main=\(app.mainWindow?.windowNumber ?? -1) modal=\(app.modalWindow?.windowNumber ?? -1)"
      + " responders=\(Self.responderChain(app.keyWindow?.firstResponder))"
      + " focusedWorkspace=\(Self.workspaceState(focusedWorkspace))"
      + " runLoop=\(RunLoop.current.currentMode?.rawValue ?? "none")"
      + " currentEventType=\(app.currentEvent?.type.rawValue ?? 0)"
  }

  private static func workspaceState(_ workspace: WorkspaceLayoutController?) -> String {
    guard let workspace else { return "nil" }
    return "\(ObjectIdentifier(workspace))"
      + "[layout=\(workspace.layout.rawValue) canToggleCapture=\(workspace.canToggleCapture)"
      + " canToggleTool=\(workspace.canToggleTool)]"
  }

  private static func windowState(_ window: NSWindow?) -> String {
    guard let window else { return "nil" }
    return "\(window.windowNumber)[class=\(className(window)) key=\(window.isKeyWindow)"
      + " main=\(window.isMainWindow) visible=\(window.isVisible)"
      + " delegate=\(className(window.delegate)) controller=\(className(window.windowController))"
      + " sheet=\(window.attachedSheet?.windowNumber ?? -1)]"
  }

  private static func responderChain(_ responder: NSResponder?) -> String {
    var current = responder
    var classes: [String] = []
    var visited: Set<ObjectIdentifier> = []
    while let responder = current, classes.count < 8 {
      guard visited.insert(ObjectIdentifier(responder)).inserted else { break }
      classes.append(className(responder))
      current = responder.nextResponder
    }
    return classes.joined(separator: ">")
  }

  private static func className(_ object: AnyObject?) -> String {
    guard let object else { return "nil" }
    return String(reflecting: type(of: object))
  }

  private static func isObservedMenuItem(_ item: NSMenuItem) -> Bool {
    let key = item.keyEquivalent.lowercased()
    let modifiers = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
    return (key == "q" && modifiers == .command)
      || (["c", "i"].contains(key) && modifiers == [.command, .option])
  }

  private static func menuItemState(_ item: NSMenuItem) -> String {
    let action = item.action.map { NSStringFromSelector($0) } ?? "nil"
    return "\(item.keyEquivalent)[enabled=\(item.isEnabled) hidden=\(item.isHidden)"
      + " action=\(action) target=\(className(item.target))]"
  }

  private static func menuState(_ menu: NSMenu?) -> String {
    guard let menu else { return "nil" }
    var entries: [String] = []
    for item in menu.items {
      if isObservedMenuItem(item) {
        entries.append(menuItemState(item))
      }
      if let submenu = item.submenu {
        let children = menuState(submenu)
        if !children.isEmpty { entries.append(children) }
      }
    }
    return entries.joined(separator: ",")
  }
}

// Focus changes stay in memory until a relevant command needs their context.
struct CommandDiagnosticHistory {
  struct Entry {
    let message: String
    let uptime: TimeInterval
  }

  private var entries: [Entry] = []
  private var droppedCount = 0

  mutating func append(_ message: String, uptime: TimeInterval) {
    if entries.count == 32 {
      entries.removeFirst()
      droppedCount += 1
    }
    entries.append(Entry(message: message, uptime: uptime))
  }

  mutating func drain() -> (entries: [Entry], droppedCount: Int) {
    let result = (entries, droppedCount)
    entries.removeAll(keepingCapacity: true)
    droppedCount = 0
    return result
  }
}
