import AppKit
import SwiftUI

/// Shared metrics for capture and network controls in the window toolbar.
enum SnapOToolbarStyle {
  static let iconFont = Font.system(size: 17, weight: .medium)
  static let singleControlSize: CGFloat = 36
}

extension View {
  @ViewBuilder
  func snapOToolbarControlStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.borderless)
    }
  }

  @ViewBuilder
  func snapOToolbarSingleControlStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.borderless)
        .glassEffect(in: Circle())
    } else {
      buttonStyle(.borderless)
        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
  }

  @ViewBuilder
  func snapOToolbarGroupStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .glassEffect(in: Capsule())
    } else {
      buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
  }
}
