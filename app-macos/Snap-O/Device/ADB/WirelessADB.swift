import Foundation

struct WirelessADBEndpoint: Equatable {
  let address: String

  init(_ value: String) throws {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Require an explicit port: pairing and debugging use different, changing ports.
    guard address.utf8.count <= 300,
          let separator = address.lastIndex(of: ":"),
          let port = UInt16(address[address.index(after: separator)...]), port > 0 else {
      throw WirelessADBError.invalidAddress
    }
    let host = String(address[..<separator])
    let validHost: Bool
    if host.hasPrefix("["), host.hasSuffix("]") {
      let literal = host.dropFirst().dropLast()
      validHost = literal.contains(":") && literal.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    } else {
      validHost = !host.isEmpty && host.utf8.allSatisfy {
        (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 46
      }
    }
    guard validHost else { throw WirelessADBError.invalidAddress }
    self.address = "\(host):\(port)"
  }
}

enum WirelessADBError: LocalizedError {
  case invalidAddress
  case invalidCode
  case pairingFailed
  case connectionFailed

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      "Enter the IP address and port shown on your phone, such as 192.168.1.10:37123."
    case .invalidCode:
      "Enter the six-digit pairing code shown on your phone."
    case .pairingFailed:
      "Pairing failed. Keep the pairing dialog open and check the address and code."
    case .connectionFailed:
      "Could not connect. Use the address on the Wireless debugging screen, not the pairing dialog."
    }
  }
}

extension ADBClient {
  func pairWirelessDevice(at endpoint: WirelessADBEndpoint, code: String) async throws {
    guard code.utf8.count == 6, code.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
      throw WirelessADBError.invalidCode
    }
    // AOSP client/commandline.cpp uses host:pair:<code>:<address>.
    // https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/commandline.cpp
    // Do not retry pairing or include the command, code, or server response in diagnostics.
    do {
      try await withTimeout(.seconds(30)).withConnection(maxAttempts: 1) { connection in
        let response = try connection.sendHostCommand("host:pair:\(code):\(endpoint.address)", expectsResponse: true)
        guard response?.hasPrefix("Successfully paired to ") == true else { throw WirelessADBError.pairingFailed }
      }
    } catch {
      try Task.checkCancellation()
      throw WirelessADBError.pairingFailed
    }
  }

  func connectWirelessDevice(at endpoint: WirelessADBEndpoint) async throws {
    do {
      try await withTimeout(.seconds(15)).withConnection(maxAttempts: 1) { connection in
        let response = try connection.sendHostCommand("host:connect:\(endpoint.address)", expectsResponse: true)
        let message = response?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message == "connected to \(endpoint.address)" || message == "already connected to \(endpoint.address)" else {
          throw WirelessADBError.connectionFailed
        }
      }
    } catch {
      try Task.checkCancellation()
      throw WirelessADBError.connectionFailed
    }
  }
}
