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
      Divider()
      Text("Servers connect automatically. SSH uses your existing keys and configuration.")
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
    .alert("Remove Server?", isPresented: Binding(
      get: { removing != nil }, set: { if !$0 { removing = nil } }
    ), presenting: removing) { profile in
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) {
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
    return HStack(alignment: .top, spacing: 12) {
      Image(systemName: profile == nil ? "desktopcomputer" : "cloud")
        .font(.title2).foregroundStyle(.secondary).frame(width: 28)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.headline).help(title)
        switch state {
        case .online:
          let count = snapshot?.inventory.connected?.count ?? 0
          Text("Connected · \(count) \(count == 1 ? "device" : "devices")").foregroundStyle(.secondary)
        case .connecting, .starting:
          Text(state == .starting ? "Starting" : "Connecting").foregroundStyle(.secondary)
        case .unavailable(let message):
          Text(message).foregroundStyle(.secondary).help(message)
        }
      }
      .font(.subheadline)
      .lineLimit(1)
      .textSelection(.disabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      if let profile {
        HStack(spacing: 8) {
          Button {
            editing = profile
          } label: {
            Label("Edit Server", systemImage: "pencil")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .help("Edit Server")
          Button(role: .destructive) {
            removing = profile
          } label: {
            Label("Remove Server", systemImage: "trash")
              .frame(width: 28, height: 28)
              .contentShape(Rectangle())
          }
          .help("Remove Server")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .disabled(servers.isUpdating)
      }
    }
    .padding(.vertical, 16)
  }
}

private struct ADBServerEditor: View {
  @Environment(\.dismiss)
  private var dismiss
  let profile: RemoteADBServer
  let isNew: Bool
  let save: (RemoteADBServer) async throws -> Void
  @State private var destination: String
  @State private var sshPort: String
  @State private var adbPort: String
  @State private var isSaving = false
  @State private var error: String?

  init(profile: RemoteADBServer, isNew: Bool, save: @escaping (RemoteADBServer) async throws -> Void) {
    self.profile = profile
    self.isNew = isNew
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
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(isNew ? "Add" : "Save") {
          isSaving = true
          Task {
            defer { isSaving = false }
            do {
              try await save(configuration())
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24).frame(width: 440)
    .disabled(isSaving)
    .interactiveDismissDisabled(isSaving)
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
    return RemoteADBServer(id: profile.id, connection: .ssh(configuration))
  }
}
