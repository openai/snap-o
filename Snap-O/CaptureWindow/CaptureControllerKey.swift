import SwiftUI

struct CaptureControllerKey: FocusedValueKey {
  typealias Value = CaptureController
}

extension FocusedValues {
  var captureController: CaptureController? {
    get { self[CaptureControllerKey.self] }
    set { self[CaptureControllerKey.self] = newValue }
  }
}
