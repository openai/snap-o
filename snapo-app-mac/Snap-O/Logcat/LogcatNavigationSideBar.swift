import AppKit
import Observation
import SwiftUI

struct LogcatNavigationSideBar: View {
  @Environment(LogcatStore.self)
  private var store: LogcatStore

  private var selection: Binding<LogcatSidebarSelection?> {
    Binding(
      get: {
        if store.isCrashPaneActive {
          return .crashes
        }
        if let id = store.activeTabID {
          return .tab(id)
        }
        return nil
      },
      set: { store.handleSidebarSelection($0) }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      sidebarList
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      bottomBar
    }
    .navigationTitle("Logcat")
  }

  private var sidebarList: some View {
    List(selection: selection) {
      LogcatDevicePickerView()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

      LogcatSidebarActionsView()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

      Section {
        LogcatCrashesRow()
          .tag(LogcatSidebarSelection.crashes)

        ForEach(store.tabs) { tab in
          LogcatTabRow(tab: tab, isSelected: selection.wrappedValue == .tab(tab.id))
            .tag(LogcatSidebarSelection.tab(tab.id))
        }
      }
      .textCase(nil)
    }
    .listStyle(.sidebar)
  }

  private var bottomBar: some View {
    let canRemoveTab = store.activeTab != nil && !store.isCrashPaneActive

    return HStack {
      Button {
        store.addTab()
      } label: {
        Image(systemName: "plus")
      }
      .help("Add a new Logcat tab")

      Spacer()

      Button(role: .destructive) {
        if let tab = store.activeTab {
          store.removeTab(tab)
        }
      } label: {
        Image(systemName: "trash")
      }
      .disabled(!canRemoveTab)
      .help("Delete the selected tab")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}

private struct LogcatCrashesRow: View {
  var body: some View {
    Text("Crashes")
      .font(.callout.weight(.medium))
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 6)
      .padding(.horizontal, 6)
  }
}

private struct LogcatTabRow: View {
  @Bindable var tab: LogcatTab
  @Environment(LogcatStore.self)
  private var store: LogcatStore
  @State private var isEditing = false
  @State private var titleDraft: String = ""
  @FocusState private var isTitleFieldFocused: Bool

  var isSelected: Bool

  var body: some View {
    let content = HStack(spacing: 8) {
      if isEditing {
        TextField("Tab Name", text: $titleDraft)
          .textFieldStyle(.plain)
          .font(.callout.weight(.medium))
          .focused($isTitleFieldFocused)
          .onSubmit { commitTitle() }
      } else {
        Text(tab.title)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())

    Group {
      if isSelected, !isEditing {
        content.onTapGesture(count: 2) {
          beginEditing()
        }
      } else {
        content
      }
    }
    .contextMenu {
      Button(role: .destructive) {
        store.removeTab(tab)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .onChange(of: isTitleFieldFocused) {
      if !isTitleFieldFocused, isEditing {
        commitTitle()
      }
    }
  }

  private func beginEditing() {
    titleDraft = tab.title
    isEditing = true
    isTitleFieldFocused = true
  }

  private func commitTitle() {
    let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      titleDraft = tab.title
    } else if trimmed != tab.title {
      tab.title = trimmed
    }
    isTitleFieldFocused = false
    isEditing = false
  }
}

private struct LogcatDevicePickerView: View {
  @Environment(LogcatStore.self)
  private var store: LogcatStore

  private var selection: Binding<String?> {
    Binding(
      get: { store.activeDeviceID },
      set: { store.selectDevice(id: $0) }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if store.devices.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "rectangle.and.hand.point.up.left.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("No devices detected")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
      } else {
        Picker(selection: selection) {
          if store.devices.isEmpty {
            Text("No devices connected").tag("")
          } else {
            ForEach(store.devices) { device in
              Text(device.displayTitle).tag(device.id)
            }
          }
        } label: {
          Text(store.activeDevice?.displayTitle ?? "Select a device")
        }
        .pickerStyle(.menu)
        .labelsHidden()
      }
    }
  }

  private func statusIndicator(text: String, color: Color) -> some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
  }
}

private struct LogcatSidebarActionsView: View {
  @Environment(LogcatStore.self)
  private var store: LogcatStore

  var body: some View {
    if store.streamingState == .noDevice {
      statusIndicator(text: "No Device", color: .red)
    } else if store.streamingState == .paused {
      statusIndicator(text: "Paused", color: .secondary)
    } else if store.streamingState == .streaming {
      statusIndicator(text: "Streaming", color: .green)
    } else {
      statusIndicator(text: "Unknown", color: .purple)
    }
  }

  private func statusIndicator(text: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
      Text(text)
        .font(.footnote)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 6)
  }
}
