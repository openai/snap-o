import AppKit
import SwiftUI

struct CaptureSheetAnchor: NSViewRepresentable {
  let isPresented: Bool

  private static let views = NSHashTable<AnchorView>.weakObjects()

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    Self.views.add(view)
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {
    view.isPresented = isPresented
  }

  static func attachmentRect(in window: NSWindow, sheet: NSWindow) -> NSRect? {
    guard let anchor = views.allObjects.first(where: { $0.window === window && $0.isPresented }) else {
      return nil
    }
    let pane = anchor.convert(anchor.bounds, to: nil)
    guard pane.width > 0, pane.height > 0 else { return nil }
    return NSRect(
      x: pane.minX,
      y: min(pane.maxY, pane.midY + sheet.frame.height / 2),
      width: pane.width,
      height: 0
    )
  }

  final class AnchorView: NSView {
    var isPresented = false

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }
  }
}
