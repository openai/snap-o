import Foundation
import SnapODeviceClient

struct URLFilterTokens {
  var includes: [String] = []
  var excludes: [String] = []
}

struct NetworkEventFilter {
  private let tokens: URLFilterTokens
  private var matchingRequestIDs = Set<String>()

  init(_ searchText: String) {
    tokens = Self.parse(searchText)
  }

  mutating func matches(_ message: NetworkCDPMessage) -> Bool {
    if tokens.includes.isEmpty, tokens.excludes.isEmpty { return true }

    let requestID = string(at: "requestId", in: message.params)
    if let url = eventURL(message), matches(url) {
      if let requestID { matchingRequestIDs.insert(requestID) }
      return true
    }
    return requestID.map(matchingRequestIDs.contains) ?? false
  }

  private func matches(_ url: String) -> Bool {
    let normalized = url.lowercased()
    return tokens.includes.allSatisfy(normalized.contains) &&
      !tokens.excludes.contains(where: normalized.contains)
  }

  private func eventURL(_ message: NetworkCDPMessage) -> String? {
    switch message.method {
    case "Network.requestWillBeSent":
      string(at: "request.url", in: message.params)
    case "Network.responseReceived":
      string(at: "response.url", in: message.params)
    case "Network.webSocketCreated":
      string(at: "url", in: message.params)
    default:
      nil
    }
  }

  private static func parse(_ searchText: String) -> URLFilterTokens {
    let characters = Array(searchText)
    var result = URLFilterTokens()
    var index = 0

    while index < characters.count {
      while index < characters.count, characters[index].isWhitespace {
        index += 1
      }
      guard index < characters.count else { break }

      let excluded = characters[index] == "-"
      if excluded { index += 1 }
      guard index < characters.count else { break }

      let quoted = characters[index] == "\""
      if quoted { index += 1 }

      var value = ""
      while index < characters.count {
        let current = characters[index]
        if quoted, current == "\"" {
          index += 1
          break
        }
        if !quoted, current.isWhitespace { break }

        if current == "\\", index + 1 < characters.count {
          let next = characters[index + 1]
          if next == "\"" || next == "\\" || (!quoted && next.isWhitespace) {
            value.append(next)
            index += 2
            continue
          }
        }

        value.append(current)
        index += 1
      }

      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !normalized.isEmpty else { continue }
      if excluded {
        result.excludes.append(normalized)
      } else {
        result.includes.append(normalized)
      }
    }
    return result
  }
}
