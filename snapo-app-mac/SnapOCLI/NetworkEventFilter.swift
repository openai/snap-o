import Foundation
import SnapODeviceClient

struct NetworkEventFilter {
  private let tokens: URLFilterTokens
  private var matchingRequestIDs = Set<String>()

  init(_ searchText: String) {
    tokens = NetworkURLFilter.parseTokens(searchText)
  }

  mutating func matches(_ message: NetworkCDPMessage) -> Bool {
    if tokens.includes.isEmpty, tokens.excludes.isEmpty { return true }

    let requestID = string(at: "requestId", in: message.params)
    if let url = eventURL(message), NetworkURLFilter.matches(url: url, tokens: tokens) {
      if let requestID { matchingRequestIDs.insert(requestID) }
      return true
    }
    return requestID.map(matchingRequestIDs.contains) ?? false
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
}
