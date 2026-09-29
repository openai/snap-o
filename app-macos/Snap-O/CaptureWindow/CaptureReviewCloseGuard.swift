import AppKit
import SwiftUI

@MainActor
struct CaptureReviewCloseGuard: NSViewRepresentable {
  let captureIDs: [UUID]
  var isSaving = false
  let discard: () throws -> Void

  private static let views = NSHashTable<GuardView>.weakObjects()

  func makeNSView(context: Context) -> GuardView {
    let view = GuardView()
    Self.views.add(view)
    return view
  }

  func updateNSView(_ view: GuardView, context: Context) {
    if view.captureIDs != captureIDs { view.discardApproved = false }
    view.captureIDs = captureIDs
    view.isSaving = isSaving
    view.discard = discard
  }

  static func confirmReplacement(discard: () throws -> Void) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Discard unsaved captures?"
    alert.informativeText = "Save these captures with the checkmark first, or discard them to continue."
    alert.addButton(withTitle: "Keep Reviewing")
    alert.addButton(withTitle: "Discard")
    guard alert.runModal() == .alertSecondButtonReturn else { return false }
    do {
      try discard()
      return true
    } catch {
      NSAlert(error: error).runModal()
      return false
    }
  }

  static func confirmDiscard(in window: NSWindow? = nil) -> Bool {
    let pending = views.allObjects.filter {
      $0.window != nil && (window == nil || $0.window === window)
        && !$0.captureIDs.isEmpty && !$0.discardApproved
    }
    guard !pending.isEmpty else { return true }
    guard !pending.contains(where: \.isSaving) else { return false }
    if let sheetOwner = pending.first(where: { $0.window?.attachedSheet != nil }) {
      sheetOwner.window?.makeKeyAndOrderFront(nil)
      return false
    }
    let alert = NSAlert()
    alert.messageText = "Discard unsaved captures?"
    alert.informativeText = "These captures are not in Capture History. Return to review to save them, or discard them before closing."
    alert.addButton(withTitle: "Review Captures")
    alert.addButton(withTitle: "Discard")
    guard alert.runModal() == .alertSecondButtonReturn else {
      pending.first?.window?.makeKeyAndOrderFront(nil)
      return false
    }
    do {
      for view in pending {
        try view.discard?()
        view.discardApproved = true
      }
      return true
    } catch {
      let failure = NSAlert(error: error)
      failure.runModal()
      return false
    }
  }

  final class GuardView: NSView {
    var captureIDs: [UUID] = []
    var isSaving = false
    var discardApproved = false
    var discard: (() throws -> Void)?
  }
}
