import Compression
import Foundation
import SnapODeviceClient

enum CLIOutputMode {
  case human
  case json
}

enum CLIOutput {
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return encoder
  }()

  private static let redactedValue = "[REDACTED]"
  private static let requestHeaderNames = Set(["authorization", "cookie"])
  private static let responseHeaderNames = Set(["set-cookie"])

  static func printJSON(_ value: some Encodable) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  static func printJSON(_ value: JSONValue) throws {
    try printJSON(JSONValueBox(value: value))
  }

  static func line(_ value: String = "") {
    Swift.print(value)
  }

  static func error(_ value: String) {
    FileHandle.standardError.write(Data("snapo: \(value)\n".utf8))
  }

  static func emitNetworkEvent(_ original: NetworkCDPMessage, mode: CLIOutputMode) throws {
    let message = sanitize(original)
    switch mode {
    case .json:
      try printJSON(message)
    case .human:
      line(formatNetworkEventLine(message))
    }
  }

  static func sanitize(_ message: NetworkCDPMessage) -> NetworkCDPMessage {
    guard let method = message.method, var params = message.params else { return message }
    switch method {
    case "Network.requestWillBeSent":
      params = redactHeaders(in: params, path: ["request", "headers"], names: requestHeaderNames)
    case "Network.responseReceived":
      params = redactHeaders(in: params, path: ["response", "headers"], names: responseHeaderNames)
    case "Network.webSocketCreated":
      params = redactHeaders(in: params, path: ["headers"], names: requestHeaderNames)
    case "Network.webSocketHandshakeResponseReceived":
      params = redactHeaders(in: params, path: ["response", "headers"], names: responseHeaderNames)
    default:
      return message
    }
    var result = message
    result.params = params
    return result
  }

  static func redactRequestHeaders(_ headers: [String: String]) -> [String: String] {
    redact(headers, names: requestHeaderNames)
  }

  static func redactResponseHeaders(_ headers: [String: String]) -> [String: String] {
    redact(headers, names: responseHeaderNames)
  }

  static func emitHeaders(_ title: String, headers: [String: String]) {
    line("\(title):")
    let entries = headers.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    if entries.isEmpty {
      line("  <none>")
    } else {
      for (name, value) in entries {
        line("  \(name): \(value)")
      }
    }
  }

  static func decodeBodyForDisplay(
    _ rawBody: String,
    encoding: String?,
    contentEncoding: String?
  ) -> String {
    guard encoding?.lowercased() == "base64",
          hasGzipContentEncoding(contentEncoding),
          let compressed = Data(base64Encoded: rawBody.trimmingCharacters(in: .whitespacesAndNewlines)),
          let uncompressed = compressed.gunzip() else {
      return rawBody
    }
    if let text = String(data: uncompressed, encoding: .utf8) {
      return text
    }
    return "Binary payload after gzip decompression (\(formatBytes(uncompressed.count))). " +
      "Raw payload is shown below as captured.\n\n\(rawBody)"
  }

  private static func formatNetworkEventLine(_ message: NetworkCDPMessage) -> String {
    guard let method = message.method else {
      return "EVENT \((try? jsonString(message)) ?? "{}")"
    }
    switch method {
    case "Network.requestWillBeSent":
      return "REQUEST \(string(at: "requestId", in: message.params) ?? "?") " +
        "\(string(at: "request.method", in: message.params) ?? "?") " +
        "\(string(at: "request.url", in: message.params) ?? "?")"
    case "Network.responseReceived":
      return "RESPONSE \(string(at: "requestId", in: message.params) ?? "?") " +
        "\(displayNumber(number(at: "response.status", in: message.params))) " +
        "\(string(at: "response.url", in: message.params) ?? "unknown-url")"
    case "Network.loadingFinished":
      return "FINISH \(string(at: "requestId", in: message.params) ?? "?") " +
        "bytes=\(displayNumber(number(at: "encodedDataLength", in: message.params), fallback: "0"))"
    case "Network.loadingFailed":
      return "FAIL \(string(at: "requestId", in: message.params) ?? "?") " +
        "\(string(at: "errorText", in: message.params) ?? string(at: "type", in: message.params) ?? "unknown-error")"
    case "Network.webSocketFrameSent":
      return "WS-SENT \(string(at: "requestId", in: message.params) ?? "?") " +
        "opcode=\(displayNumber(number(at: "response.opcode", in: message.params))) " +
        "size=\(displayNumber(number(at: "response.payloadSize", in: message.params), fallback: "0"))"
    case "Network.webSocketFrameReceived":
      return "WS-RECV \(string(at: "requestId", in: message.params) ?? "?") " +
        "opcode=\(displayNumber(number(at: "response.opcode", in: message.params))) " +
        "size=\(displayNumber(number(at: "response.payloadSize", in: message.params), fallback: "0"))"
    default:
      return "EVENT \(method)"
    }
  }

  private static func displayNumber(_ value: Double?, fallback: String = "?") -> String {
    guard let value else { return fallback }
    return value.rounded() == value ? String(Int(value)) : String(value)
  }

  private static func hasGzipContentEncoding(_ value: String?) -> Bool {
    guard let value else { return false }
    return value
      .split { $0 == "," || $0 == "\n" }
      .map { $0.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .contains { $0 == "gzip" || $0 == "x-gzip" }
  }

  private static func formatBytes(_ count: Int) -> String {
    switch count {
    case ..<1000: "\(count) B"
    case ..<1_000_000: String(format: "%.1f KB", Double(count) / 1000)
    case ..<1_000_000_000: String(format: "%.1f MB", Double(count) / 1_000_000)
    default: String(format: "%.1f GB", Double(count) / 1_000_000_000)
    }
  }

  private static func jsonString(_ value: some Encodable) throws -> String {
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private static func redact(_ headers: [String: String], names: Set<String>) -> [String: String] {
    headers.mapValues { $0 }.reduce(into: [:]) { result, entry in
      result[entry.key] = names.contains(entry.key.lowercased()) ? redactedValue : entry.value
    }
  }

  private static func redactHeaders(
    in root: [String: JSONValue],
    path: ArraySlice<String>,
    names: Set<String>
  ) -> [String: JSONValue] {
    guard let key = path.first else {
      return root.reduce(into: [:]) { result, entry in
        result[entry.key] = names.contains(entry.key.lowercased()) ? .string(redactedValue) : entry.value
      }
    }
    guard case .object(let child)? = root[key] else { return root }
    var updated = root
    updated[key] = .object(redactHeaders(in: child, path: path.dropFirst(), names: names))
    return updated
  }
}

private extension Data {
  func gunzip() -> Data? {
    guard count >= 18, self[startIndex] == 0x1F, self[index(startIndex, offsetBy: 1)] == 0x8B else {
      return nil
    }
    guard self[index(startIndex, offsetBy: 2)] == 8 else { return nil }

    let flags = self[index(startIndex, offsetBy: 3)]
    guard flags & 0xE0 == 0 else { return nil }
    var cursor = index(startIndex, offsetBy: 10)
    let trailerStart = index(endIndex, offsetBy: -8)

    if flags & 0x04 != 0 {
      guard distance(from: cursor, to: trailerStart) >= 2 else { return nil }
      let length = Int(self[cursor]) | Int(self[index(after: cursor)]) << 8
      cursor = index(cursor, offsetBy: 2)
      guard distance(from: cursor, to: trailerStart) >= length else { return nil }
      cursor = index(cursor, offsetBy: length)
    }
    if flags & 0x08 != 0 {
      guard let terminator = self[cursor ..< trailerStart].firstIndex(of: 0) else { return nil }
      cursor = index(after: terminator)
    }
    if flags & 0x10 != 0 {
      guard let terminator = self[cursor ..< trailerStart].firstIndex(of: 0) else { return nil }
      cursor = index(after: terminator)
    }
    if flags & 0x02 != 0 {
      guard distance(from: cursor, to: trailerStart) >= 2 else { return nil }
      cursor = index(cursor, offsetBy: 2)
    }
    guard cursor <= trailerStart else { return nil }

    let sizeBytes = suffix(4)
    let outputSize = sizeBytes.enumerated().reduce(0) { result, entry in
      result | Int(entry.element) << (entry.offset * 8)
    }
    if outputSize == 0 { return Data() }

    let compressed = self[cursor ..< trailerStart]
    var output = [UInt8](repeating: 0, count: outputSize)
    let decodedSize = output.withUnsafeMutableBytes { destination in
      compressed.withUnsafeBytes { source in
        guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress,
              let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else {
          return 0
        }
        return compression_decode_buffer(
          destinationAddress,
          destination.count,
          sourceAddress,
          source.count,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    guard decodedSize == outputSize else { return nil }
    return Data(output)
  }
}

private struct JSONValueBox: Encodable {
  let value: JSONValue

  func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }
}

func value(at path: String, in root: [String: JSONValue]?) -> JSONValue? {
  var current = root.map(JSONValue.object)
  for segment in path.split(separator: ".").map(String.init) {
    guard case .object(let object)? = current else { return nil }
    current = object[segment]
  }
  return current
}

func string(at path: String, in root: [String: JSONValue]?) -> String? {
  guard case .string(let value)? = value(at: path, in: root) else { return nil }
  return value
}

func number(at path: String, in root: [String: JSONValue]?) -> Double? {
  guard case .number(let value)? = value(at: path, in: root) else { return nil }
  return value
}

func bool(at path: String, in root: [String: JSONValue]?) -> Bool? {
  guard case .bool(let value)? = value(at: path, in: root) else { return nil }
  return value
}

func headers(at path: String, in root: [String: JSONValue]?) -> [String: String] {
  guard case .object(let object)? = value(at: path, in: root) else { return [:] }
  return object.reduce(into: [:]) { result, entry in
    switch entry.value {
    case .string(let value): result[entry.key] = value
    case .number(let value): result[entry.key] = String(value)
    case .bool(let value): result[entry.key] = String(value)
    case .null: result[entry.key] = "null"
    case .array, .object: result[entry.key] = (try? JSONEncoder().encode(entry.value))
      .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
  }
}

func headerValue(_ headers: [String: String], named name: String) -> String? {
  headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}
