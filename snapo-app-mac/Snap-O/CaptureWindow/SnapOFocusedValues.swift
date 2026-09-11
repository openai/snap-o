import SwiftUI

private struct CaptureControllerKey: FocusedValueKey {
  typealias Value = CaptureWindowController
}

private struct WorkspaceControllerKey: FocusedValueKey {
  typealias Value = WorkspaceLayoutController
}

private struct InspectorHostKey: FocusedValueKey {
  typealias Value = InspectorHostModel
}

extension FocusedValues {
  var inspectorHost: InspectorHostModel? {
    get { self[InspectorHostKey.self] }
    set { self[InspectorHostKey.self] = newValue }
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
