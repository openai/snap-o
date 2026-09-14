import Foundation
import NIOHTTP1
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ToolSchemeHandler: NSObject, WKURLSchemeHandler, URLSessionTaskDelegate {
  var bundle: ToolFrontendBundle?
  private let developmentURL: URL?
  private var endpoint: ToolHTTPService.Endpoint?
  private var tasks: [ObjectIdentifier: (api: Bool, task: Task<Void, Never>)] = [:]
  private var session: URLSession?

  init(developmentURL: URL? = nil) {
    self.developmentURL = developmentURL
    super.init()
    if developmentURL != nil {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
  }

  var entryURL: URL? {
    if let developmentURL {
      var components = URLComponents(url: developmentURL, resolvingAgainstBaseURL: false)
      components?.scheme = ToolURL.scheme
      components?.host = ToolURL.host
      components?.port = nil
      components?.fragment = nil
      if components?.path.isEmpty == true { components?.path = "/" }
      return components?.url
    }
    return bundle.map { ToolURL.frontend.appendingPathComponent($0.entryPoint) }
  }

  func authorize(_ endpoint: ToolHTTPService.Endpoint?) {
    for (id, request) in tasks where request.api {
      request.task.cancel()
      tasks[id] = nil
    }
    self.endpoint = endpoint
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, url.scheme == ToolURL.scheme, url.host == ToolURL.host,
          url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else {
      urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
      return
    }
    let api = ToolURL.isAPI(url)
    let endpoint = endpoint
    guard !api || endpoint != nil else {
      urlSchemeTask.didFailWithError(URLError(.userAuthenticationRequired))
      return
    }
    let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
    tasks[identifier] = (api, Task {
      defer { tasks[identifier] = nil }
      do {
        try Task.checkCancellation()
        if api, let endpoint {
          let input = try ToolHTTPRequestInput(request: urlSchemeTask.request)
          let operation = ToolHTTPRequestOperation(input: input) {
            try await endpoint.adb.openLocalAbstract(
              deviceID: endpoint.reference.deviceId, abstractSocket: endpoint.reference.socketName
            )
          }
          try await operation.run(onResponse: { response in
            try Task.checkCancellation()
            try urlSchemeTask.didReceive(Self.response(response, url: url))
          }, onData: { data in
            try Task.checkCancellation()
            urlSchemeTask.didReceive(data)
          })
        } else {
          guard urlSchemeTask.request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
          let (data, response) = try await asset(url)
          try Task.checkCancellation()
          try urlSchemeTask.didReceive(Self.response(response, url: url))
          urlSchemeTask.didReceive(data)
        }
        try Task.checkCancellation()
        urlSchemeTask.didFinish()
      } catch {
        if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
      }
    })
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.task.cancel()
  }

  func invalidate() {
    endpoint = nil
    for request in tasks.values {
      request.task.cancel()
    }
    tasks.removeAll()
    session?.invalidateAndCancel()
    session = nil
  }

  private func asset(_ url: URL) async throws -> (Data, HTTPResponseHead) {
    if let developmentURL, let session {
      var upstream = URLComponents(url: url, resolvingAgainstBaseURL: false)
      upstream?.scheme = developmentURL.scheme
      upstream?.host = developmentURL.host
      upstream?.port = developmentURL.port
      guard let upstreamURL = upstream?.url else { throw URLError(.badURL) }
      let (data, response) = try await session.data(from: upstreamURL)
      guard let response = response as? HTTPURLResponse, !(300 ..< 400).contains(response.statusCode) else {
        throw URLError(.badServerResponse)
      }
      var headers = HTTPHeaders(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) })
      // URLSession decodes compression; WebKit needs headers for the decoded bytes.
      headers.remove(name: "Content-Encoding")
      headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
      return (data, HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.statusCode), headers: headers))
    }
    guard let data = bundle?.files[String(url.path(percentEncoded: false).dropFirst())] else { throw URLError(.fileDoesNotExist) }
    return (data, HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([
      ("Content-Type", Self.contentType(for: url)),
      ("Content-Length", String(data.count)),
      ("Content-Security-Policy", ToolWebPolicy.contentSecurityPolicy),
      ("Cache-Control", "no-store"),
      ("X-Content-Type-Options", "nosniff")
    ])))
  }

  private static func response(_ response: HTTPResponseHead, url: URL) throws -> HTTPURLResponse {
    // WebKit receives decoded body bytes, not the upstream connection's framing.
    var headers = response.headers
    for name in headers[canonicalForm: "Connection"] + [
      "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade"
    ] {
      headers.remove(name: String(name))
    }
    guard let value = HTTPURLResponse(
      url: url, statusCode: Int(response.status.code), httpVersion: "HTTP/1.1",
      headerFields: Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { $0 + ", " + $1 })
    ) else { throw ToolHTTPTransportError.invalidResponse }
    return value
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  private static func contentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "html": "text/html; charset=utf-8"
    case "json", "map": "application/json; charset=utf-8"
    default: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
  }
}
