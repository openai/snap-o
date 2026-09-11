import SwiftUI

struct CaptureSelectionPill: View {
  let position: String

  var body: some View {
    Text(position)
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .monospacedDigit()
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .fixedSize()
      .background(.regularMaterial, in: Capsule())
  }
}
