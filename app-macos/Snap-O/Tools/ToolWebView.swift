import SwiftUI
import WebKit

struct ToolWebView: NSViewRepresentable {
  let model: PluginHostModel

  func makeNSView(context: Context) -> NSView {
    NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let webView = model.webContainer?.webView
    guard nsView.subviews.first !== webView else { return }
    nsView.subviews.forEach { $0.removeFromSuperview() }
    guard let webView else { return }
    webView.translatesAutoresizingMaskIntoConstraints = false
    nsView.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
      webView.topAnchor.constraint(equalTo: nsView.topAnchor),
      webView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor)
    ])
  }
}
