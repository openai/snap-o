import AppKit
import Observation
import SwiftUI

struct NetworkInspectorExportMenu: View {
  @Bindable var model: NetworkInspectorHostModel
  @State private var menuPresenter = NetworkInspectorExportMenuPresenter()

  var body: some View {
    Button {
      menuPresenter.present(model: model)
    } label: {
      Image(systemName: "square.and.arrow.up")
        .font(SnapOToolbarStyle.iconFont)
        .frame(
          width: SnapOToolbarStyle.singleControlSize,
          height: SnapOToolbarStyle.singleControlSize
        )
        .accessibilityLabel("Export")
        .background {
          NetworkInspectorExportMenuAnchor(presenter: menuPresenter)
            .allowsHitTesting(false)
        }
    }
    .help("Export requests")
    .disabled(!model.isPageReady || (model.selectedRecordKind == nil && !model.hasVisibleRecords))
    .controlSize(.extraLarge)
    .snapOToolbarSingleControlStyle()
  }
}

private struct NetworkInspectorExportMenuAnchor: NSViewRepresentable {
  let presenter: NetworkInspectorExportMenuPresenter

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    presenter.anchorView = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    presenter.anchorView = nsView
  }
}

@MainActor
private final class NetworkInspectorExportMenuPresenter: NSObject {
  weak var anchorView: NSView?
  private var model: NetworkInspectorHostModel?

  func present(model: NetworkInspectorHostModel) {
    guard let anchorView, anchorView.window != nil else { return }
    self.model = model

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(
      menuItem(
        title: "Export HAR (sanitized)…",
        systemImage: "doc.badge.arrow.up",
        action: #selector(exportHar),
        isEnabled: model.hasVisibleRecords
      )
    )
    menu.addItem(.separator())
    menu.addItem(
      menuItem(
        title: "Copy URL",
        systemImage: "link",
        action: #selector(copyURL),
        isEnabled: model.selectedRecordKind != nil
      )
    )
    menu.addItem(
      menuItem(
        title: "Copy as CURL",
        systemImage: "terminal",
        action: #selector(copyCurl),
        isEnabled: model.selectedRecordKind == "request"
      )
    )

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchorView)
    self.model = nil
  }

  private func menuItem(
    title: String,
    systemImage: String,
    action: Selector,
    isEnabled: Bool
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    item.isEnabled = isEnabled
    return item
  }

  @objc
  private func exportHar() {
    model?.exportVisibleRecordsAsHar()
  }

  @objc
  private func copyURL() {
    model?.copySelectedURL()
  }

  @objc
  private func copyCurl() {
    model?.copySelectedCurl()
  }
}
