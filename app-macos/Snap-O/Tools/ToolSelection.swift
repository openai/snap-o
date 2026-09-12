import Foundation

struct ToolSelection {
  private struct Preference: Codable {
    let deviceId: String
    let processName: String
    let androidUserId: Int?
    let kind: ToolID

    func matches(_ app: InspectableApp) -> Bool {
      deviceId == app.deviceId && androidUserId == app.androidUserId && processName == app.processName
    }
  }

  private struct Preferences: Codable {
    var last: Preference?
    var apps: [Preference] = []
  }

  private var saved = Preferences()
  private var target: InspectableApp?
  private var kind: ToolID?
  private var current: SelectedAppTool?
  private var retained: [ToolID: SelectedAppTool] = [:]
  private var apps: [InspectableApp] = []
  private var awaitingAppIdentity = false
  private var startupSelectionPending = true

  init(saved raw: String? = nil) {
    guard let raw, let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = object["apps"] as? [Any] else { return }
    saved.apps = entries.compactMap(Self.decodePreference)
    saved.last = object["last"].flatMap(Self.decodePreference)
    kind = saved.last?.kind
  }

  var serialized: String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(saved)).flatMap { String(data: $0, encoding: .utf8) }
  }

  var state: AppToolState {
    AppToolState(
      apps: apps,
      selection: current,
      displayed: retained,
      selectedApp: target,
      replacementApp: replacementApp,
      preferredKind: kind,
      isRestoring: awaitingAppIdentity || (current == nil && (kind != nil || apps.contains { !$0.tools.isEmpty }))
    )
  }

  mutating func reconcile(_ apps: [InspectableApp]) {
    self.apps = apps
    if awaitingAppIdentity {
      if let app = apps.first(where: { $0.id == target?.id }) {
        updateTarget(app)
        if Self.hasIdentity(app) { selectApp(app) }
      }
      return
    }
    let exact = apps.first { $0.id == target?.id && Self.sameApp(target, $0) }
    let app = exact ?? saved.last.flatMap { preference in
      preference.androidUserId == nil ? nil : apps.first(where: preference.matches)
    }
    // Preserve saved choices while discovery returns partial results.
    if startupSelectionPending, saved.last == nil,
       let first = apps.first(where: { Self.hasIdentity($0) && $0.tools.contains(where: \.isConnected) })
       ?? apps.first(where: { Self.hasIdentity($0) && $0.tools.contains { $0.compatibility.isUnsupported } }) {
      selectApp(first)
      return
    }
    if let app, let kind {
      if let target, app.id != target.id, !retained.isEmpty {
        // A replacement process needs an explicit choice before receiving requests.
        current = nil
      } else {
        updateTarget(app)
        remember(app, kind: kind)
        setCurrent(app, option: app.tools.first { $0.kind == kind })
        if current != nil { startupSelectionPending = false }
      }
    } else {
      current = nil
    }
  }

  mutating func selectApp(_ app: InspectableApp) {
    startupSelectionPending = false
    guard Self.hasIdentity(app) else {
      updateTarget(app)
      current = nil
      retained = [:]
      awaitingAppIdentity = true
      return
    }
    let preferredKind = saved.apps.first { $0.matches(app) }?.kind
      ?? app.tools.first { $0.kind == kind }?.kind
      ?? app.tools.first { $0.isConnected && !$0.compatibility.isUnsupported }?.kind
      ?? app.tools.first?.kind
    if let preferredKind { selectKind(app, kind: preferredKind) }
  }

  mutating func selectTool(_ app: InspectableApp, option: AppToolOption) {
    selectKind(app, kind: option.kind)
  }

  private var replacementApp: InspectableApp? {
    guard current == nil, let target, Self.hasIdentity(target), let kind else { return nil }
    return apps.first {
      $0.id != target.id && Self.sameApp(target, $0) && $0.tools.contains { $0.kind == kind }
    }
  }

  private mutating func selectKind(_ app: InspectableApp, kind: ToolID) {
    startupSelectionPending = false
    if !Self.sameApp(target, app) { retained = [:] }
    awaitingAppIdentity = false
    updateTarget(app)
    self.kind = kind
    saved.last = nil
    remember(app, kind: kind)
    // Cached toolbar options express intent, not permission to reuse an old socket.
    let liveApp = apps.first { $0.id == app.id && Self.sameApp(app, $0) }
    setCurrent(liveApp ?? app, option: liveApp?.tools.first { $0.kind == kind })
  }

  private mutating func updateTarget(_ app: InspectableApp) {
    var options: [ToolID: AppToolOption] = [:]
    if let target, Self.sameApp(target, app) {
      for option in target.tools {
        options[option.kind] = option
      }
    }
    for option in app.tools {
      options[option.kind] = option
    }
    target = app
    target?.tools = options.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
  }

  private mutating func setCurrent(_ app: InspectableApp, option: AppToolOption?) {
    guard let option, option.isConnected else { current = nil
      return
    }
    current = SelectedAppTool(
      appId: app.id, kind: option.kind, server: option.server, protocolVersion: option.protocolVersion
    )
    retained[option.kind] = current
  }

  private mutating func remember(_ app: InspectableApp, kind: ToolID) {
    guard let processName = app.processName, !processName.isEmpty else { return }
    let preference = Preference(
      deviceId: app.deviceId, processName: processName, androidUserId: app.androidUserId, kind: kind
    )
    saved.last = preference
    saved.apps.removeAll { $0.matches(app) }
    saved.apps.append(preference)
  }

  private static func sameApp(_ first: InspectableApp?, _ second: InspectableApp) -> Bool {
    guard let first, first.deviceId == second.deviceId else { return false }
    if first.androidUserId != second.androidUserId, first.androidUserId != nil || first.id != second.id { return false }
    if hasIdentity(first), hasIdentity(second) { return first.processName == second.processName }
    return first.id == second.id
  }

  private static func hasIdentity(_ app: InspectableApp) -> Bool {
    app.processName?.isEmpty == false
  }

  private static func decodePreference(_ object: Any) -> Preference? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let preference = try? JSONDecoder().decode(Preference.self, from: data),
          !preference.processName.isEmpty,
          preference.androidUserId.map({ $0 >= 0 }) ?? true else { return nil }
    return preference
  }
}
