import SwiftUI

extension EnvironmentValues {
  @Entry var captureImageCopied: @MainActor () -> Void = {}
}

struct CaptureCopyConfirmation: View {
  let copyID: UUID?

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var pendingCopyID: UUID?
  @State private var isVisible = false

  var body: some View {
    Text("Copied")
      .font(.callout.weight(.medium))
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(.regularMaterial, in: Capsule())
      .opacity(isVisible ? 1 : 0)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isVisible)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onChange(of: copyID) { _, newValue in
        pendingCopyID = newValue
      }
      .task(id: pendingCopyID) {
        guard pendingCopyID != nil else { return }
        isVisible = true
        AccessibilityNotification.Announcement("Image copied").post()
        do {
          try await Task.sleep(for: .milliseconds(1200))
        } catch {
          return
        }
        isVisible = false
      }
      .onDisappear {
        pendingCopyID = nil
        isVisible = false
      }
  }
}
