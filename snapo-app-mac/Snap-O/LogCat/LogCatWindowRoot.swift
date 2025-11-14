import SwiftUI

@MainActor
struct LogCatWindowRoot: View {
  @State private var store: LogCatStore

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    _store = State(
      initialValue: LogCatStore(
        adbService: adbService,
        deviceTracker: deviceTracker
      )
    )
  }

  var body: some View {
    NavigationSplitView {
      LogCatNavigationSideBar()
    } detail: {
      LogCatDetailView()
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
