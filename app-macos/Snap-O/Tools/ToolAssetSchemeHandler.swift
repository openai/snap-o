import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ToolAssetSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "snapo-inspector"
  let baseURL: URL
  var bundle: ToolFrontendBundle?

  init(storageIdentifier: UUID?) {
    guard let url = URL(string: "\(Self.scheme)://\((storageIdentifier ?? UUID()).uuidString.lowercased())/") else {
      preconditionFailure("Invalid tool asset URL")
    }
    baseURL = url
    super.init()
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, url.scheme == Self.scheme, url.host == baseURL.host,
          url.port == nil, url.user == nil, url.password == nil,
          urlSchemeTask.request.httpMethod == "GET",
          let data = bundle?.files[String(url.path(percentEncoded: false).dropFirst())],
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

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

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
