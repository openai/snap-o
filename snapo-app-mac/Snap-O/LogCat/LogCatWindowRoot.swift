import SwiftUI

@MainActor
struct LogCatWindowRoot: View {
  @StateObject private var store: LogCatStore
  @StateObject private var deviceStore: DeviceStore
  @State private var deviceTask: Task<Void, Never>?

  init(services: AppServices) {
    let deviceStore = DeviceStore(tracker: services.deviceTracker)
    _deviceStore = StateObject(wrappedValue: deviceStore)
    _store = StateObject(wrappedValue: LogCatStore(
      services: services,
      deviceStore: deviceStore
    ))
  }

  var body: some View {
    NavigationSplitView {
      LogCatNavigationSideBar()
    } detail: {
      LogCatDetailView()
    }
    .environmentObject(store)
    .onAppear {
      if deviceTask == nil {
        deviceTask = Task {
          await deviceStore.start()
        }
      }
      store.start()
    }
    .onDisappear {
      deviceTask?.cancel()
      deviceTask = nil
      store.stop()
    }
  }
}
