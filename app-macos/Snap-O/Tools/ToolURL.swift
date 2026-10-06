import Foundation

enum ToolURL {
  static let scheme = "snapo"
  static let host = "tool"
  static let frontend = url("snapo://tool/")
  static let api = url("snapo://tool/api/")

  static func isAPI(_ url: URL) -> Bool {
    let path = url.path(percentEncoded: true)
    return url.scheme == scheme && url.host == host && url.port == nil && url.user == nil && url.password == nil
      && url.fragment == nil && (path == "/api" || path.hasPrefix("/api/"))
  }

  private static func url(_ literal: String) -> URL {
    guard let url = URL(string: literal) else {
      preconditionFailure("Invalid tool URL: \(literal)")
    }
    return url
  }
}
