import AppKit
import Foundation

enum NetworkInspectorCopyExporter {
  static func copyURL(_ url: String) {
    setPasteboard(string: url)
  }

  static func copyCurl(for request: NetworkInspectorRequestViewModel) {
    let command = makeCurlCommand(for: request)
    setPasteboard(string: command)
  }

  private static func setPasteboard(string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }

  private static func makeCurlCommand(for request: NetworkInspectorRequestViewModel) -> String {
    var warnings: [String] = []
    var parts: [String] = []

    parts.append("--request \(singleQuoted(request.method))")
    parts.append("--url \(singleQuoted(request.url))")

    for header in request.requestHeaders {
      parts.append("--header \(singleQuoted("\(header.name): \(header.value)"))")
    }

    if let bodyArgument = makeBodyArgument(for: request) {
      parts.append(bodyArgument.argument)
      warnings.append(contentsOf: bodyArgument.warnings)
    }

    let command = joinCurlParts(parts)
    guard !warnings.isEmpty else {
      return command
    }

    let warningLines = warnings.map { "# \($0)" }
    return (warningLines + [command]).joined(separator: "\n")
  }

  private static func makeBodyArgument(for request: NetworkInspectorRequestViewModel) -> (argument: String, warnings: [String])? {
    guard let body = request.requestBody else { return nil }

    var warnings: [String] = []

    if body.isPreview, body.truncatedBytes == nil {
      warnings.append("Request body is a preview – copied data may be incomplete")
    }

    if let truncated = body.truncatedBytes, truncated > 0 {
      warnings.append("Request body truncated by \(formatBytes(truncated)) – copied data may be incomplete")
    }

    let encoding = body.encoding?.lowercased()

    if encoding == "base64" {
      if let data = Data(base64Encoded: body.rawText) {
        let literal = makeBinaryLiteral(from: data)
        return ("--data-binary \(literal)", warnings)
      } else {
        warnings.append("Unable to decode base64 body – copied data uses raw text")
        return ("--data-binary \(singleQuoted(body.rawText))", warnings)
      }
    } else {
      return ("--data-binary \(singleQuoted(body.rawText))", warnings)
    }
  }

  private static func joinCurlParts(_ parts: [String]) -> String {
    guard !parts.isEmpty else { return "curl" }

    var remaining = parts
    let first = remaining.removeFirst()
    var firstLine = "curl \(first)"

    if !remaining.isEmpty {
      let second = remaining.removeFirst()
      firstLine += " \(second)"
    }

    guard !remaining.isEmpty else {
      return firstLine
    }

    var lines: [String] = []
    lines.append(firstLine + " \\")

    for (index, part) in remaining.enumerated() {
      let isLast = index == remaining.count - 1
      var line = "  \(part)"
      if !isLast {
        line += " \\"
      }
      lines.append(line)
    }

    return lines.joined(separator: "\n")
  }

  private static func singleQuoted(_ string: String) -> String {
    if string.isEmpty {
      return "''"
    }
    let escaped = string.replacingOccurrences(of: "'", with: "'\"'\"'")
    return "'\(escaped)'"
  }

  private static func makeBinaryLiteral(from data: Data) -> String {
    var result = "$'"
    result.reserveCapacity(data.count * 4)

    for byte in data {
      switch byte {
      case 0x07:
        result.append("\\a")
      case 0x08:
        result.append("\\b")
      case 0x09:
        result.append("\\t")
      case 0x0A:
        result.append("\\n")
      case 0x0B:
        result.append("\\v")
      case 0x0C:
        result.append("\\f")
      case 0x0D:
        result.append("\\r")
      case 0x5C:
        result.append("\\\\")
      case 0x27:
        result.append("\\'")
      default:
        if byte >= 0x20 && byte <= 0x7E {
          let scalar = Unicode.Scalar(byte)
          result.append(Character(scalar))
        } else {
          result.append(String(format: "\\x%02X", byte))
        }
      }
    }

    result.append("'")
    return result
  }

  private static func formatBytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: value)
  }
}
