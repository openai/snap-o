import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("Network URL filter")
struct NetworkURLFilterTests {
  @Test("matches the shared URL filter contract")
  func matchesSharedContract() throws {
    let fixtureURL = repositoryRoot
      .appendingPathComponent("contracts/network/v1/url-filter.json")
    let data = try Data(contentsOf: fixtureURL)
    let contract = try JSONDecoder().decode(URLFilterContract.self, from: data)

    #expect(contract.version == 1)

    for testCase in contract.cases {
      let tokens = NetworkURLFilter.parseTokens(testCase.searchText)
      #expect(tokens == testCase.tokens, "Unexpected tokens for \(testCase.id)")

      for match in testCase.matches {
        let result = NetworkURLFilter.matches(url: match.url, tokens: tokens)
        #expect(result == match.expected, "Unexpected match for \(testCase.id) url=\(match.url)")
      }
    }
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private struct URLFilterContract: Decodable {
  let version: Int
  let cases: [URLFilterContractCase]
}

private struct URLFilterContractCase: Decodable {
  let id: String
  let searchText: String
  let tokens: URLFilterTokens
  let matches: [URLFilterContractMatch]
}

private struct URLFilterContractMatch: Decodable {
  let url: String
  let expected: Bool
}
