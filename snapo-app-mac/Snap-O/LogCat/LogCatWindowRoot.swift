import SwiftUI

@MainActor
struct LogCatWindowRoot: View {
  @StateObject private var store: LogCatStore

  init(adbService: ADBService, deviceTracker: DeviceTracker) {
    _store = StateObject(
      wrappedValue: LogCatStore(
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
    .environmentObject(store)
    .onAppear {
      store.start()
    }
    .onDisappear {
      store.stop()
    }
  }
}
