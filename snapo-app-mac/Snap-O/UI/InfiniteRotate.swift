import SwiftUI

struct InfiniteRotate: ViewModifier {
  var duration: Double
  var animated: Bool
  @State private var spin = false
  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(spin ? 360 : 0))
      .animation(
        animated ? .linear(duration: duration).repeatForever(autoreverses: false) : .none,
        value: spin
      )
      .onAppear { spin = animated }
      .onChange(of: animated) { _, newValue in
        spin = newValue
      }
  }
}

extension View {
  func infiniteRotate(duration: Double = 10, animated: Bool = true) -> some View {
    modifier(InfiniteRotate(duration: duration, animated: animated))
  }
}
