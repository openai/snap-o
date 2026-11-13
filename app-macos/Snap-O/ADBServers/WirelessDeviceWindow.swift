import SwiftUI

struct WirelessDeviceWindow: View {
  @State private var pairingAddress = ""
  @State private var pairingCode = ""
  @State private var connectionAddress = ""
  @State private var status: String?
  @State private var isBusy = false
  @State private var operation: Task<Void, Never>?

  var body: some View {
    Form {
      Section {
        Text("""
        Connect your phone and Mac to the same Wi-Fi network. \
        On Android 11 or later, enable Developer options → Wireless debugging.
        """)
        Text("""
        Pairing allows this Mac to debug and control your phone. \
        You can revoke access under Paired devices on your phone.
        """)
        .foregroundStyle(.secondary)
      }
      Section("1. Pair this Mac") {
        Text("On your phone, tap Pair device with pairing code. Keep that dialog open.")
        TextField("Pairing address", text: $pairingAddress, prompt: Text("192.168.1.10:37123"))
        SecureField("Pairing code", text: $pairingCode, prompt: Text("Six digits"))
        Button("Pair") { run(pair: true) }
          .disabled(isBusy || pairingAddress.isEmpty || pairingCode.isEmpty)
      }
      Section("2. Connect") {
        Text("""
        After pairing, return to Wireless debugging. Enter its IP address and port. \
        This port differs from the pairing port. Skip pairing if this Mac is already paired.
        """)
        TextField("Connection address", text: $connectionAddress, prompt: Text("192.168.1.10:40217"))
        Button("Connect") { run(pair: false) }
          .disabled(isBusy || connectionAddress.isEmpty)
      }
      if isBusy { ProgressView().controlSize(.small) }
      if let status { Text(status).textSelection(.enabled) }
    }
    .formStyle(.grouped)
    .frame(width: 540)
    .navigationTitle("Connect Android Wirelessly")
    .onDisappear {
      operation?.cancel()
      pairingCode = ""
    }
  }

  private func run(pair: Bool) {
    isBusy = true
    status = nil
    let address = pair ? pairingAddress : connectionAddress
    let code = pairingCode
    pairingCode = ""
    operation = Task { @MainActor in
      defer { isBusy = false }
      do {
        let endpoint = try WirelessADBEndpoint(address)
        let host = AndroidHostClient()
        defer { host.close() }
        try await host.ensureADBServerRunning()
        if pair {
          try await ADBClient().pairWirelessDevice(at: endpoint, code: code)
          status = "Paired. If your phone does not appear in Device Manager, use its connection address below."
        } else {
          try await ADBClient().connectWirelessDevice(at: endpoint)
          status = "Connected. Select your phone in Device Manager, then open Live Preview."
        }
      } catch {
        if !Task.isCancelled { status = error.localizedDescription }
      }
    }
  }
}
