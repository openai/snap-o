import SwiftUI
import WebKit

struct NetworkInspectorWebView: NSViewRepresentable {
  let model: NetworkInspectorHostModel

  func makeNSView(context: Context) -> WKWebView {
    model.webContainer.webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
