import SwiftUI

struct DeviceManagerWindow: View {
  @Environment(\.openWindow)
  private var openWindow
  @State private var deviceToDelete: ManagedEmulator?
  @Bindable var manager: DeviceManager

  var body: some View {
    VStack(spacing: 0) {
      if let error = manager.loadError {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer(minLength: 0)
        }
        .padding()
        Divider()
      }
      if !manager.hasLoaded || !manager.matchingSerials.isEmpty, manager.entries.isEmpty {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if manager.entries.isEmpty {
        ContentUnavailableView {
          Label("No Devices", systemImage: "iphone.gen3")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(manager.entries) { device in
              row(device)
              Divider().padding(.leading, 56)
            }
          }
          .padding(.horizontal, 20)
        }
      }
    }
    .frame(minWidth: 620, minHeight: 300)
    .navigationTitle("Device Manager")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await manager.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .disabled(manager.isRefreshing)
        .help("Refresh Devices")
      }
      .sharedBackgroundVisibility(.hidden)
    }
    .alert("Device Manager", isPresented: Binding(
      get: { manager.actionError != nil },
      set: { if !$0 { manager.actionError = nil } }
    )) {
      Button("OK") { manager.actionError = nil }
    } message: {
      Text(manager.actionError ?? "")
    }
    .alert("Delete Emulator?", isPresented: Binding(
      get: { deviceToDelete != nil },
      set: { if !$0 { deviceToDelete = nil } }
    ), presenting: deviceToDelete) { device in
      Button("Cancel", role: .cancel) { deviceToDelete = nil }
      Button("Delete", role: .destructive) {
        manager.delete(device)
        deviceToDelete = nil
      }
    } message: { device in
      Text("“\(device.title)” and its data will move to Trash.")
    }
  }

  private func row(_ entry: DeviceManagerEntry) -> some View {
    let emulator: ManagedEmulator? = if case .emulator(let device) = entry { device } else { nil }
    let action = emulator.flatMap { manager.actions[$0.id] }
    let status = emulator.flatMap { manager.startupStatus(for: $0) }
    return HStack(alignment: .center, spacing: 16) {
      DeviceThumbnailView(device: entry, action: status, manager: manager)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          guard action == nil else { return }
          if entry.canOpenPreview, let serial = entry.serial {
            showPreview(serial)
          } else if let device = emulator, device.canStart, manager.loadError == nil {
            manager.start(device)
          }
        }
      VStack(alignment: .leading, spacing: 5) {
        Text(entry.title).font(.headline)
          .lineLimit(1)
        Text(entry.subtitle)
          .font(.subheadline).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let status {
        Text(status)
          .foregroundStyle(Color(nsColor: .disabledControlTextColor))
          .fixedSize()
          .frame(height: 28)
      }
      if entry.canOpenPreview, let serial = entry.serial {
        Button { showPreview(serial) } label: {
          Text("Open")
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .help("Open in Live Preview")
        .disabled(action != nil)
      }
      if let device = emulator {
        emulatorControls(device, action: action, status: status)
      } else {
        Color.clear.frame(width: 72, height: 28)
      }
    }
    .buttonStyle(.plain)
    .padding(.vertical, 14)
    .contextMenu {
      if let device = emulator {
        actions(for: device).disabled(action != nil || manager.loadError != nil)
      }
    }
  }

  private func emulatorControls(_ device: ManagedEmulator, action: String?, status: String?) -> some View {
    HStack(spacing: 16) {
      if action == nil, device.canStop {
        Button { manager.stop(device) } label: {
          actionIcon("Stop", symbol: "stop.fill")
        }
        .help("Stop")
      } else if let status {
        ProgressView()
          .controlSize(.small)
          .frame(width: 28, height: 28)
          .accessibilityLabel(status)
          .help(status)
      } else if device.canStart {
        Button { manager.start(device) } label: {
          actionIcon("Start", symbol: "play.fill")
        }
        .help("Start")
      } else {
        Color.clear.frame(width: 28, height: 28)
      }
      Menu {
        actions(for: device)
      } label: {
        actionIcon("Emulator Actions", symbol: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 28, height: 28)
      .disabled(action != nil)
      .help("Emulator Actions")
    }
    .frame(width: 72, height: 28)
    .disabled(manager.loadError != nil)
  }

  @ViewBuilder
  private func actions(for device: ManagedEmulator) -> some View {
    Button("Cold Boot", systemImage: "arrow.counterclockwise") { manager.start(device, coldBoot: true) }
      .disabled(!device.canColdBoot)
    Button("Reveal in Finder", systemImage: "folder") {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.id)])
    }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive) { deviceToDelete = device }
      .disabled(!device.canDelete)
  }

  private func actionIcon(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .labelStyle(.iconOnly)
      .font(SnapOToolbarStyle.iconFont)
      .frame(width: 28, height: 28)
      .contentShape(Rectangle())
  }

  private func showPreview(_ serial: String) {
    if !SnapOCommandCoordinator.shared.showLivePreview(deviceID: serial) {
      openWindow(id: WorkspaceWindowID.main, value: WorkspaceWindowConfiguration(workspace: .persisted()))
    }
  }
}
