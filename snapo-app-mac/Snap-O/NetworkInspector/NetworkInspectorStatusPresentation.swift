import Foundation
import SwiftUI

enum NetworkInspectorStatusPresentation {
  static func color(for code: Int) -> Color {
    switch code {
    case 200 ..< 300:
      .green
    case 400 ..< 600:
      .red
    case 300 ..< 400:
      .orange
    case 100 ..< 200:
      .secondary
    default:
      .secondary
    }
  }

  static func displayName(for code: Int) -> String {
    if let override = overrides[code] {
      return "\(code) \(override)"
    }

    let raw = HTTPURLResponse.localizedString(forStatusCode: code)
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    let descriptor: String = if trimmed.isEmpty || trimmed == "unknown" {
      "Done"
    } else if trimmed.lowercased() == "ok" {
      "OK"
    } else if trimmed.lowercased() == "no error" {
      "OK"
    } else {
      trimmed.capitalized
    }

    return "\(code) \(descriptor)"
  }

  private static let overrides: [Int: String] = [
    200: "OK",
    201: "Created",
    202: "Accepted",
    204: "No Content",
    301: "Moved Permanently",
    302: "Found",
    304: "Not Modified",
    307: "Temporary Redirect",
    308: "Permanent Redirect",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    409: "Conflict",
    410: "Gone",
    422: "Unprocessable Entity",
    429: "Too Many Requests",
    500: "Internal Server Error",
    501: "Not Implemented",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout"
  ]
}
