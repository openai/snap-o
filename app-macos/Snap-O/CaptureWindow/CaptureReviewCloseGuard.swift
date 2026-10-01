import AppKit
import SwiftUI

@MainActor
struct CaptureReviewCloseGuard: NSViewRepresentable {
  let captureIDs: [UUID]
  var isSaving = false
  let discard: () -> Void

  private static let views = NSHashTable<GuardView>.weakObjects()

  func makeNSView(context: Context) -> GuardView {
    let view = GuardView()
    Self.views.add(view)
    return view
  }

  func updateNSView(_ view: GuardView, context: Context) {
    if view.captureIDs != captureIDs { view.didDiscard = false }
    view.captureIDs = captureIDs
    view.isSaving = isSaving
    view.discard = discard
  }

  static func prepareToClose(in window: NSWindow? = nil) -> Bool {
    let pending = views.allObjects.filter {
      $0.window != nil && (window == nil || $0.window === window)
        && !$0.captureIDs.isEmpty && !$0.didDiscard
    }
    guard !pending.isEmpty else { return true }
    guard !pending.contains(where: \.isSaving) else { return false }
    if let sheetOwner = pending.first(where: { $0.window?.attachedSheet != nil }) {
      sheetOwner.window?.makeKeyAndOrderFront(nil)
      return false
    }
    for view in pending {
      view.discard?()
      view.didDiscard = true
    }
    return true
  }

  final class GuardView: NSView {
    var captureIDs: [UUID] = []
    var isSaving = false
    var didDiscard = false
    var discard: (() -> Void)?
  }
}
