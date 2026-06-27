import Foundation

public struct URLFilterTokens: Equatable, Sendable {
  public var includes: [String]
  public var excludes: [String]

  public init(includes: [String] = [], excludes: [String] = []) {
    self.includes = includes
    self.excludes = excludes
  }
}

public enum NetworkURLFilter {
  public static func parseTokens(_ searchText: String) -> URLFilterTokens {
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

  public static func matches(url: String, tokens: URLFilterTokens) -> Bool {
    if tokens.includes.isEmpty, tokens.excludes.isEmpty { return true }

    let normalized = url.lowercased()
    return tokens.includes.allSatisfy(normalized.contains) &&
      !tokens.excludes.contains(where: normalized.contains)
  }
}
