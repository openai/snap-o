import SwiftUI

struct WorkspaceWindowLauncher: ViewModifier {
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      SnapOCommandCoordinator.shared.openWorkspace = {
        openWindow(id: WorkspaceWindowID.main, value: WorkspaceWindowConfiguration(workspace: .persisted()))
      }
    }
  }
}
