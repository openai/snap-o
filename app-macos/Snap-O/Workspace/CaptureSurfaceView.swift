import SwiftUI

struct CapturePaneBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .headerView
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct CaptureSurfaceView<Content: View>: View {
  let aspectRatio: CGFloat?
  @ViewBuilder var content: () -> Content

  var body: some View {
    GeometryReader { geometry in
      let paneAspectRatio = geometry.size.width / max(geometry.size.height, 1)

      // Keep the preview mounted when its display size becomes available.
      content()
        .aspectRatio(aspectRatio ?? paneAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
