import SwiftUI

struct CaptureWindowKey: FocusedValueKey {
  typealias Value = CaptureWindowCoordinator
}

extension FocusedValues {
  var captureWindow: CaptureWindowCoordinator? {
    get { self[CaptureWindowKey.self] }
    set { self[CaptureWindowKey.self] = newValue }
  }
}
