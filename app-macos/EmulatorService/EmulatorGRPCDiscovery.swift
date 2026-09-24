import CryptoKit
import Foundation

/// Reads host registration files without granting the sandboxed app filesystem access.
final class EmulatorGRPCDiscovery {
  enum Access {
    case screenshot, clipboard, rotation

    var methods: [String] {
      switch self {
      case .screenshot: ["streamScreenshot"]
      case .clipboard: ["getClipboard", "setClipboard", "streamClipboard"]
      case .rotation: ["getScreenshot", "setPhysicalModel"]
      }
    }
  }

  private let directory: URL
  private let isProcessRunning: (Int32) -> Bool
  private let signingKey = P256.Signing.PrivateKey()
  private let keyID = UUID().uuidString

  init(
    home: URL? = nil,
    isProcessRunning: @escaping (Int32) -> Bool = { kill($0, 0) == 0 }
  ) {
    let path = getpwuid(getuid()).flatMap(\.pointee.pw_dir).map { String(cString: $0) } ?? NSHomeDirectory()
    directory = (home ?? URL(fileURLWithPath: path))
      .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    self.isProcessRunning = isProcessRunning
  }

  func endpoint(for serial: String, access: Access = .screenshot) throws -> EmulatorGRPCEndpoint? {
    guard EmulatorGRPCEndpoint.isEmulator(serial) else {
      throw EmulatorServiceError(message: "This device is not a local Android emulator.")
    }
    let port = String(serial.dropFirst(9))
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "ini" && file.lastPathComponent.hasPrefix("pid_") {
      guard let pid = Int32(file.deletingPathExtension().lastPathComponent.dropFirst(4)),
            pid > 0, isProcessRunning(pid),
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            let size = attributes[.size] as? NSNumber, size.intValue <= 65536,
            let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      let properties = ManagedEmulator.properties(text)
      guard properties["port.serial"] == port else { continue }
      guard let grpcPort = properties["grpc.port"].flatMap(Int.init), (1024 ... 65535).contains(grpcPort) else {
        return try pendingEndpoint(access: access)
      }
      guard properties["grpc.server_cert"] == nil, properties["grpc.certificate"] == nil else {
        throw EmulatorServiceError(message: "This emulator requires gRPC TLS. Start it from Snap-O to use Live Preview.")
      }
      if let token = properties["grpc.token"], !token.isEmpty {
        return EmulatorGRPCEndpoint(port: grpcPort, token: token)
      }
      if let jwks = properties["grpc.jwks"], let active = properties["grpc.jwk_active"] {
        guard let credentials = try jwtToken(
          keyDirectory: URL(fileURLWithPath: jwks),
          activeFile: URL(fileURLWithPath: active),
          access: access
        )
        else { return try pendingEndpoint(access: access) }
        return EmulatorGRPCEndpoint(port: grpcPort, token: credentials.token, expiresAt: credentials.expiresAt)
      }
      guard access != .clipboard else { throw unavailable() }
      return EmulatorGRPCEndpoint(port: grpcPort, token: nil)
    }
    return try pendingEndpoint(access: access)
  }

  private func pendingEndpoint(access: Access) throws -> EmulatorGRPCEndpoint? {
    guard access == .screenshot else { throw unavailable() }
    return nil
  }

  private func unavailable() -> EmulatorServiceError {
    EmulatorServiceError(message: "The emulator's gRPC connection is unavailable. Restart the emulator from Snap-O and try again.")
  }

  private func jwtToken(keyDirectory: URL, activeFile: URL, access: Access) throws -> (token: String, expiresAt: Date)? {
    let publicKey = signingKey.publicKey.rawRepresentation
    let jwk: [String: Any] = [
      "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig",
      "key_ops": ["verify"], "kid": keyID,
      "x": Self.base64URL(publicKey.prefix(32)),
      "y": Self.base64URL(publicKey.suffix(32))
    ]
    // Only a public verification key is written, inside the emulator's temporary directory.
    // Reuse it for this helper's lifetime; the emulator owns the directory's cleanup.
    let keyFile = keyDirectory.appendingPathComponent("snap-o-\(keyID).jwk")
    if !FileManager.default.fileExists(atPath: keyFile.path) {
      try JSONSerialization.data(withJSONObject: ["keys": [jwk]]).write(to: keyFile, options: .atomic)
    }

    let deadline = Date().addingTimeInterval(2)
    while !Self.containsKey(keyID, in: activeFile) {
      guard Date() < deadline else {
        try? FileManager.default.removeItem(at: keyFile)
        return nil
      }
      Thread.sleep(forTimeInterval: 0.05)
    }

    let now = Int(Date().timeIntervalSince1970)
    let header = try Self.encodedJSON(["alg": "ES256", "typ": "JWT", "kid": keyID])
    let claims = try Self.encodedJSON([
      "iss": "Snap-O", "iat": now, "exp": now + 900,
      "aud": access.methods.map { "/android.emulation.control.EmulatorController/" + $0 }
    ])
    let content = header + "." + claims
    let signature = try signingKey.signature(for: Data(content.utf8))
    return (content + "." + Self.base64URL(signature.rawRepresentation), Date(timeIntervalSince1970: TimeInterval(now + 900)))
  }

  private static func containsKey(_ id: String, in file: URL) -> Bool {
    guard let data = try? Data(contentsOf: file),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let keys = object["keys"] as? [[String: Any]] else { return false }
    return keys.contains { $0["kid"] as? String == id }
  }

  private static func encodedJSON(_ value: [String: Any]) throws -> String {
    try base64URL(JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
  }

  private static func base64URL(_ data: some DataProtocol) -> String {
    Data(data).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
