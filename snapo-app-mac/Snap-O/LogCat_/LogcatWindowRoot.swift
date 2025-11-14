import SwiftUI

@MainActor
struct LogcatWindowRoot: View {
  @State private var store: LogcatStore

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    _store = State(
      initialValue: LogcatStore(
        adbService: adbService,
        deviceTracker: deviceTracker
      )
    )
  }

  var body: some View {
    NavigationSplitView {
      LogcatNavigationSideBar()
    } detail: {
      LogcatDetailView()
    }
    .environment(store)
    .onAppear {
      store.start()
    }
    .onDisappear {
      store.stop()
    }
  }
}
