import SwiftUI

struct CaptureSurfaceView<Content: View>: View {
  let aspectRatio: CGFloat?
  @ViewBuilder var content: () -> Content

  var body: some View {
    GeometryReader { geometry in
      let paneAspectRatio = geometry.size.width / max(geometry.size.height, 1)

      ZStack {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        // Keep the media view mounted when the inspector changes the sizing policy.
        content()
          .aspectRatio(aspectRatio ?? paneAspectRatio, contentMode: .fit)
      }
    }
  }
}
