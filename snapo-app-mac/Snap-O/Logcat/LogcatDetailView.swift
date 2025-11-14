import AppKit
import Observation
import OSLog
import SwiftUI

struct LogcatDetailView: View {
  @Environment(LogcatStore.self)
  private var store: LogcatStore

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(store.isCrashPaneActive ? "Crashes" : (store.activeTab?.title ?? "Logcat"))
      .toolbar {
        if let tab = store.activeTab, !store.isCrashPaneActive {
          ToolbarItemGroup(placement: .primaryAction) {
            Text("\(tab.renderedEntries.count) entries")
              .font(.caption2)
              .foregroundStyle(.secondary)

            Button {
              tab.isPaused.toggle()
            } label: {
              Label(tab.isPaused ? "Resume" : "Pause", systemImage: tab.isPaused ? "play.fill" : "pause.fill")
            }
            .help(tab.isPaused ? "Resume streaming logs into this tab" : "Pause log streaming for this tab")
          }
        }
      }
  }

  @ViewBuilder private var content: some View {
    if store.isCrashPaneActive {
      LogcatCrashContentView()
    } else if let tab = store.activeTab {
      LogcatTabContentView(tab: tab)
    } else {
      LogcatPlaceholderView(
        icon: "rectangle.stack",
        title: "Pick a Tab",
        message: "Choose a tab in the sidebar or create a new one to start streaming logs."
      )
    }
  }
}
