import SwiftUI

struct CaptureWindow: View {
  let appCoordinator: AppCoordinator

  @State private var windowCoordinator: CaptureWindowCoordinator

  init(appCoordinator: AppCoordinator) {
    self.appCoordinator = appCoordinator
    _windowCoordinator = State(
      initialValue: CaptureWindowCoordinator(
        adbClient: appCoordinator.adbClient,
        fileStore: appCoordinator.fileStore,
        recordingService: appCoordinator.recordingService,
        recordingStore: appCoordinator.recordingStore
      )
    )
  }

  var body: some View {
    CaptureContentView(coordinator: windowCoordinator, deviceStore: appCoordinator.deviceStore)
      .focusedSceneValue(\.captureWindow, windowCoordinator)
  }
}
