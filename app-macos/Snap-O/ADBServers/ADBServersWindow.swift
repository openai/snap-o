import AppKit
import SwiftUI

struct ADBServersWindow: View {
  @Bindable var servers: ADBServers
  @State private var editing: RemoteADBServer?
  @State private var removing: RemoteADBServer?

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 0) {
          row(title: "This Mac (:5037)", id: .local, profile: nil)
          ForEach(servers.profiles) { profile in
            Divider()
            row(title: profile.connection.displayAddress, id: .remote(profile.id), profile: profile)
          }
        }
        .padding(.horizontal, 20)
      }
    }
    .frame(minWidth: 540, minHeight: 260)
    .navigationTitle("ADB Servers")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Server", systemImage: "plus") {
          editing = RemoteADBServer(id: UUID(), connection: .ssh(SSHConfiguration(destination: "")))
        }
        .disabled(servers.isUpdating)
      }
    }
    .sheet(item: $editing) { profile in
      ADBServerEditor(profile: profile, isNew: !servers.profiles.contains { $0.id == profile.id }) {
        try await servers.save($0)
      }
    }
    .alert("Delete Server?", isPresented: Binding(
      get: { removing != nil }, set: { if !$0 { removing = nil } }
    ), presenting: removing) { profile in
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        Task {
          do { try await servers.remove(profile) } catch { servers.error = error.localizedDescription }
        }
      }
    } message: { profile in
      Text("Disconnect the devices on “\(profile.connection.displayAddress)” and remove this saved connection.")
    }
    .alert("ADB Servers", isPresented: Binding(
      get: { servers.error != nil }, set: { if !$0 { servers.error = nil } }
    )) {
      Button("OK") { servers.error = nil }
    } message: { Text(servers.error ?? "") }
  }

  private func row(title: String, id: ADBServerID, profile: RemoteADBServer?) -> some View {
    let snapshot = servers.snapshots.first { $0.id == id }
    let state = snapshot?.state ?? .connecting
    let isUpdating = profile.map { servers.updatingServerID == $0.id } ?? false
    let isDisconnecting = profile?.isEnabled == false && isUpdating
    let isConnecting = profile?.isEnabled != false && (isUpdating || state == .connecting || state == .starting)
    let isConnected = profile?.isEnabled != false && !isUpdating && state == .online
    let deviceCount = snapshot?.inventory.connected?.count ?? 0
    let status: String = if isDisconnecting {
      "Disconnecting"
    } else if profile?.isEnabled == false {
      "Disconnected"
    } else if isConnecting {
      state == .starting && !isUpdating ? "Starting" : "Connecting"
    } else {
      switch state {
      case .online: "Connected"
      case .connecting: "Connecting"
      case .starting: "Starting"
      case .unavailable(let message): message
      }
    }
    return HStack(alignment: .firstTextBaseline, spacing: 12) {
      Toggle("Enable \(title)", isOn: Binding(
        get: { profile?.isEnabled ?? true },
        set: { enabled in
          guard let profile else { return }
          Task {
            do {
              try await servers.setEnabled(enabled, for: profile)
            } catch { servers.error = error.localizedDescription }
          }
        }
      ))
      .toggleStyle(.checkbox)
      .labelsHidden()
      .fixedSize()
      .disabled(profile == nil || servers.isUpdating)
      .help(profile == nil ? "Local ADB discovery is always enabled." : "Enable or disable this server.")
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Image(systemName: profile == nil ? "desktopcomputer" : "cloud")
          .font(.title2)
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .alignmentGuide(.firstTextBaseline) { dimensions in
            dimensions[VerticalAlignment.center] + NSFont.preferredFont(forTextStyle: .headline).capHeight / 2
          }
          .accessibilityHidden(true)
        Text(title).font(.headline).help(title)
          .truncationMode(.middle)
          .lineLimit(1)
          .textSelection(.disabled)
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        guard let profile, !servers.isUpdating else { return }
        editing = profile
      }
      Group {
        if isConnecting || isDisconnecting {
          ProgressView().controlSize(.small).fixedSize()
        } else {
          Circle().fill(isConnected ? Color.green : Color.red)
            .frame(width: 6, height: 6)
        }
      }
      .frame(width: 16, height: 16)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[VerticalAlignment.center] + NSFont.preferredFont(forTextStyle: .headline).capHeight / 2
      }
      .help(status)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(status)
      .accessibilityAddTraits(.isImage)
      if isConnected {
        Text("\(deviceCount) \(deviceCount == 1 ? "device" : "devices")")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      Spacer(minLength: 0)
      if let profile {
        Menu {
          Button("Edit", systemImage: "pencil") { editing = profile }
          Button("Delete", systemImage: "trash", role: .destructive) { removing = profile }
        } label: {
          Label("Server Options", systemImage: "ellipsis")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Server Options")
        .disabled(servers.isUpdating)
      }
    }
    .padding(.vertical, 10)
  }
}

struct ADBServerEditor: View {
  @Environment(\.dismiss)
  private var dismiss
  let profile: RemoteADBServer
  let isNew: Bool
  let opensDevice: Bool
  let onClose: (() -> Void)?
  let save: (RemoteADBServer) async throws -> Void
  @State private var destination: String
  @State private var sshPort: String
  @State private var adbPort: String
  @State private var isSaving = false
  @State private var error: String?

  init(
    profile: RemoteADBServer, isNew: Bool, opensDevice: Bool = false,
    onClose: (() -> Void)? = nil, save: @escaping (RemoteADBServer) async throws -> Void
  ) {
    self.profile = profile
    self.isNew = isNew
    self.opensDevice = opensDevice
    self.onClose = onClose
    self.save = save
    switch profile.connection {
    case .ssh(let configuration):
      _destination = State(initialValue: configuration.destination)
      _sshPort = State(initialValue: configuration.port.map(String.init) ?? "")
      _adbPort = State(initialValue: configuration.adbPort == 5037 ? "" : String(configuration.adbPort))
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(isNew ? "Add ADB Server" : "Edit ADB Server").font(.title2.bold())
      Form {
        LabeledContent("SSH server") {
          HStack(spacing: 8) {
            TextField("SSH server", text: $destination, prompt: Text("user@host or SSH alias"))
            TextField("SSH port", text: $sshPort, prompt: Text("Port (22)"))
              .frame(width: 88)
              .help("SSH port. Leave blank to use your SSH configuration.")
          }
          .labelsHidden()
        }
        TextField("ADB port", text: $adbPort, prompt: Text("5037"))
      }
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
        if !opensDevice {
          saveButton.keyboardShortcut(.defaultAction)
        } else {
          saveButton
        }
      }
    }
    .padding(24).frame(width: 440)
    .disabled(isSaving)
    .interactiveDismissDisabled(isSaving)
  }

  private var saveButton: some View {
    Button(opensDevice ? "Add and Open" : (isNew ? "Add" : "Save")) {
      isSaving = true
      Task {
        defer { isSaving = false }
        do {
          try await save(configuration())
          close()
        } catch { self.error = error.localizedDescription }
      }
    }
    .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func close() {
    if let onClose { onClose() } else { dismiss() }
  }

  private func configuration() throws -> RemoteADBServer {
    let ssh = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
    let adb = adbPort.trimmingCharacters(in: .whitespacesAndNewlines)
    guard ssh.isEmpty || UInt16(ssh).map({ $0 > 0 }) == true,
          let adbNumber = UInt16(adb.isEmpty ? "5037" : adb), adbNumber > 0 else {
      throw ADBError.protocolFailure("Ports must be between 1 and 65535.")
    }
    let configuration = SSHConfiguration(
      destination: destination.trimmingCharacters(in: .whitespacesAndNewlines), port: UInt16(ssh), adbPort: adbNumber
    )
    try configuration.validate()
    return RemoteADBServer(id: profile.id, connection: .ssh(configuration), isEnabled: profile.isEnabled)
  }
}
