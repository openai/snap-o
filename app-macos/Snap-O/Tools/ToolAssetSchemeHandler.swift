import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ToolAssetSchemeHandler: NSObject, WKURLSchemeHandler, URLSessionTaskDelegate {
  static let scheme = ToolURL.scheme
  let baseURL = ToolURL.frontend
  var bundle: ToolFrontendBundle?
  private let developmentURL: URL?
  private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
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
    return bundle.map { baseURL.appendingPathComponent($0.entryPoint) }
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, url.scheme == Self.scheme, url.host == ToolURL.host,
          url.port == nil, url.user == nil, url.password == nil,
          !ToolURL.isAPI(url),
          urlSchemeTask.request.httpMethod == "GET" else {
      urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
      return
    }
    if let developmentURL, let session {
      let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
      tasks[identifier] = Task {
        do {
          var upstream = URLComponents(url: url, resolvingAgainstBaseURL: false)
          upstream?.scheme = developmentURL.scheme
          upstream?.host = developmentURL.host
          upstream?.port = developmentURL.port
          guard let upstreamURL = upstream?.url else { throw URLError(.badURL) }
          let (data, response) = try await session.data(from: upstreamURL)
          try Task.checkCancellation()
          guard let response = response as? HTTPURLResponse, !(300 ..< 400).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
          }
          // URLSession decodes compression; WebKit needs headers for the decoded bytes.
          var headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            result[String(describing: field.key).lowercased()] = String(describing: field.value)
          }
          for name in ["connection", "transfer-encoding", "content-encoding"] {
            headers[name] = nil
          }
          headers["content-length"] = String(data.count)
          guard let proxied = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
          else {
            throw URLError(.badServerResponse)
          }
          urlSchemeTask.didReceive(proxied)
          urlSchemeTask.didReceive(data)
          urlSchemeTask.didFinish()
        } catch {
          if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
        }
        tasks[identifier] = nil
      }
      return
    }
    guard let data = bundle?.files[String(url.path(percentEncoded: false).dropFirst())],
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.contentType(for: url),
            "Content-Length": String(data.count),
            "Content-Security-Policy": ToolWebPolicy.contentSecurityPolicy,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
          ]) else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
  }

  func invalidate() {
    for task in tasks.values {
      task.cancel()
    }
    tasks.removeAll()
    session?.invalidateAndCancel()
    session = nil
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
