import AppKit
import SwiftUI

/// Shared metrics for capture and tool controls in the window toolbar.
enum SnapOToolbarStyle {
  static let iconSize: CGFloat = 17
  static let iconFont = Font.system(size: iconSize, weight: .medium)
  static let singleControlSize: CGFloat = 36
}

struct CaptureActionIcon: View {
  let title: String
  let symbol: String

  var body: some View {
    Label(title, systemImage: symbol)
      .labelStyle(.iconOnly)
      .font(SnapOToolbarStyle.iconFont)
      .captureActionIconFrame()
  }
}

extension View {
  func captureActionIconFrame() -> some View {
    frame(width: 34, height: 32)
      .contentShape(Rectangle())
  }

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
