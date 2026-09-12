import SwiftUI

private struct CaptureControllerKey: FocusedValueKey {
  typealias Value = CaptureWindowController
}

private struct WorkspaceControllerKey: FocusedValueKey {
  typealias Value = WorkspaceLayoutController
}

private struct ToolHostKey: FocusedValueKey {
  typealias Value = ToolHostModel
}

extension FocusedValues {
  var toolHost: ToolHostModel? {
    get { self[ToolHostKey.self] }
    set { self[ToolHostKey.self] = newValue }
  }

  var captureController: CaptureWindowController? {
    get { self[CaptureControllerKey.self] }
    set { self[CaptureControllerKey.self] = newValue }
  }

  var workspaceController: WorkspaceLayoutController? {
    get { self[WorkspaceControllerKey.self] }
    set { self[WorkspaceControllerKey.self] = newValue }
  }
}
