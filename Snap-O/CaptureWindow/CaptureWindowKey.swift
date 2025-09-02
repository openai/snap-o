import SwiftUI

struct CaptureWindowKey: FocusedValueKey {
  typealias Value = CaptureController
}

extension FocusedValues {
  var captureWindow: CaptureController? {
    get { self[CaptureWindowKey.self] }
    set { self[CaptureWindowKey.self] = newValue }
  }
}
