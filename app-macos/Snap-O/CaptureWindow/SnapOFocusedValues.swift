import SwiftUI

private struct CaptureControllerKey: FocusedValueKey {
  typealias Value = CaptureWindowController
}

private struct WorkspaceControllerKey: FocusedValueKey {
  typealias Value = WorkspaceLayoutController
}

private struct PluginHostKey: FocusedValueKey {
  typealias Value = PluginHostModel
}

extension FocusedValues {
  var toolHost: PluginHostModel? {
    get { self[PluginHostKey.self] }
    set { self[PluginHostKey.self] = newValue }
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
