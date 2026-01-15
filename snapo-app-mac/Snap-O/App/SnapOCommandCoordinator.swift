import Foundation

@MainActor
final class SnapOCommandCoordinator {
  static let shared = SnapOCommandCoordinator()

  private init() {}

  func handle(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "snapo" else { return false }
    guard let command = SnapOCommand.from(url: url) else { return false }
    NotificationCenter.default.post(
      name: .snapoCommandRequested,
      object: command
    )
    return true
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

extension Notification.Name {
  static let snapoCommandRequested = Notification.Name("SnapOCommandRequested")
}
