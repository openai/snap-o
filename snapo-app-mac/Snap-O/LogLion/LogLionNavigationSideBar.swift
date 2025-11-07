import SwiftUI

struct LogLionNavigationSideBar: View {
  @EnvironmentObject private var store: LogLionStore
  
  private var selection: Binding<UUID?> {
    Binding(
      get: { store.activeTabID },
      set: { store.setActiveTab($0) }
    )
  }
  
  var body: some View {
    List(selection: selection) {
      LogLionDevicePickerView(store: store)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      
      LogLionSidebarActionsView(store: store)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      
      Section("Tabs") {
        ForEach(store.tabs) { tab in
          LogLionTabRow(tab: tab)
            .environmentObject(store)
            .tag(tab.id)
            .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
      }
      .textCase(nil)
    }
    .listStyle(.sidebar)
    .navigationTitle("LogLion")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.addTab()
        } label: {
          Label("New Tab", systemImage: "plus")
        }
        .help("Add a new LogLion tab")
      }
    }
  }
}

private struct LogLionTabRow: View {
  @ObservedObject var tab: LogLionTab
  @EnvironmentObject private var store: LogLionStore

  @State private var isPopoverPresented = false
  
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: tab.isPaused ? "pause.circle.fill" : "play.circle.fill")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(tab.title)
            .foregroundStyle(.primary)
          if tab.unreadCount > 0 {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 6, height: 6)
            if let badge = formattedUnread(tab.unreadCount) {
              Text(badge)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            }
          }
        }
      }
      Spacer()
      Button {
        tab.isPaused.toggle()
      } label: {
        Image(systemName: tab.isPaused ? "play.circle" : "pause.circle")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(tab.isPaused ? "Resume this tab" : "Pause this tab")
      Button {
        isPopoverPresented = true
      } label: {
        Image(systemName: "square.and.pencil")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("edit name")
      Button {
        store.removeTab(tab)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("delete tab")
      .disabled(store.tabs.count <= 1)
    }
    .padding(.vertical, 4)
    .popover(isPresented: $isPopoverPresented) {
      VStack(alignment: .leading) {
        Text("Name")
        TextField("Title", text: Binding(
          get: { tab.title },
          set: { tab.title = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        Button() {
          isPopoverPresented = false
        } label: {
          Text("Done")
        }
      }
      .padding(16)
      .frame(width: 200)
    }
  }

  private func formattedUnread(_ count: Int) -> String? {
    switch count {
    case 0..<10:
      return nil
    case 10..<50:
      return "\(count/10*10)+"
    case 60..<100:
      return "50+"
    default:
      return "100+"
    }
  }
}

private struct LogLionDevicePickerView: View {
  @ObservedObject var store: LogLionStore
  
  private var selection: Binding<String?> {
    Binding(
      get: { store.activeDeviceID },
      set: { store.selectDevice(id: $0) }
    )
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Device")
        .font(.caption2)
        .foregroundStyle(.secondary)
      
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
          HStack(spacing: 12) {
            Text(store.activeDevice?.displayTitle ?? "Select a device")
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
      }
    }
  }
}

private struct LogLionSidebarActionsView: View {
  @ObservedObject var store: LogLionStore
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Status")
        .font(.caption)
        .foregroundColor(.secondary)
      HStack() {
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
  }
}
