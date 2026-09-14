import Foundation
import NIOHTTP1
import WebKit

@MainActor
final class ToolAPISchemeHandler: NSObject, WKURLSchemeHandler {
  private var endpoint: ToolHTTPService.Endpoint?
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

  func authorize(_ endpoint: ToolHTTPService.Endpoint?) {
    for task in tasks.values {
      task.cancel()
    }
    tasks.removeAll()
    self.endpoint = endpoint
  }

  func invalidate() {
    authorize(nil)
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let endpoint, let url = urlSchemeTask.request.url,
          ToolURL.isAPI(url) else {
      urlSchemeTask.didFailWithError(URLError(.userAuthenticationRequired))
      return
    }

    let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
    tasks[identifier] = Task {
      defer { tasks[identifier] = nil }
      do {
        try Task.checkCancellation()
        let input = try ToolHTTPRequestInput(request: urlSchemeTask.request)
        let operation = ToolHTTPRequestOperation(input: input) {
          try await endpoint.adb.openLocalAbstract(
            deviceID: endpoint.reference.deviceId,
            abstractSocket: endpoint.reference.socketName
          )
        }
        try await operation.run(
          onResponse: { response in
            try Task.checkCancellation()
            try urlSchemeTask.didReceive(Self.response(response, url: url))
          },
          onData: { data in
            try Task.checkCancellation()
            urlSchemeTask.didReceive(data)
          }
        )
        try Task.checkCancellation()
        urlSchemeTask.didFinish()
      } catch {
        if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
      }
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
  }

  private static func response(_ response: HTTPResponseHead, url: URL) throws -> HTTPURLResponse {
    // WebKit receives decoded body bytes, not the upstream connection's framing.
    var headers = response.headers
    let connectionHeaders = headers[canonicalForm: "Connection"]
    for name in connectionHeaders + [
      "Connection",
      "Keep-Alive",
      "Proxy-Authenticate",
      "Proxy-Authorization",
      "TE",
      "Trailer",
      "Transfer-Encoding",
      "Upgrade"
    ] {
      headers.remove(name: String(name))
    }
    guard let value = HTTPURLResponse(
      url: url,
      statusCode: Int(response.status.code),
      httpVersion: "HTTP/1.1",
      headerFields: Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { $0 + ", " + $1 })
    ) else { throw ToolHTTPTransportError.invalidResponse }
    return value
  }
}
