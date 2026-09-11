import CryptoKit
import Foundation
import SnapODeviceClient

enum InspectorWebPolicy {
  static func storageIdentifier(app: InspectableApp?, inspector: InspectorID) -> UUID? {
    guard let app, let manifest = app.manifest, manifest.processIdentity != nil,
          let package = manifest.app?.packageName, let user = manifest.androidUserId else { return nil }
    let scope = ["snapo.inspector.v2", app.deviceId, String(user), package, inspector.rawValue]
    guard let data = try? JSONEncoder().encode(scope) else { return nil }
    let bytes = Array(SHA256.hash(data: data).prefix(16))
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  static func isInspectorEndpoint(_ url: URL) -> Bool {
    url.scheme == "http" && url.host == "127.0.0.1" && url.port.map { (1 ... 65535).contains($0) } == true
      && url.user == nil && url.password == nil && url.path == "/" && url.query == nil && url.fragment == nil
  }

  static func contentRules(endpoint: URL?, developmentURL: URL?) throws -> String {
    if let endpoint, !isInspectorEndpoint(endpoint) { throw InspectorError.invalidBridgeMessage }
    var allowed = ["^data:", "^blob:"]
    for url in [endpoint, developmentURL].compactMap(\.self) {
      guard let origin = origin(of: url) else { throw InspectorError.invalidBridgeMessage }
      allowed.append("^" + NSRegularExpression.escapedPattern(for: origin) + "/")
      let socket = origin.replacingOccurrences(of: "https://", with: "wss://")
        .replacingOccurrences(of: "http://", with: "ws://")
      allowed.append("^" + NSRegularExpression.escapedPattern(for: socket) + "/")
    }
    let rules: [[String: Any]] = [
      ["trigger": ["url-filter": ".*"], "action": ["type": "block"]]
    ] + allowed.map {
      ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]]
    }
    guard let encoded = try String(data: JSONSerialization.data(withJSONObject: rules), encoding: .utf8) else {
      throw InspectorError.invalidBridgeMessage
    }
    return encoded
  }

  static func protectedHTML(_ html: String) -> String {
    // Content rules narrow loopback access to this page's exact endpoint, including redirects and network hints.
    let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
      + "connect-src http://127.0.0.1:* ws://127.0.0.1:* data: blob:; "
      + "img-src data: blob:; font-src data:; media-src blob:; worker-src 'none'; frame-src 'none'; "
      + "object-src 'none'; base-uri 'none'; form-action 'none'"
    return "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + html
  }

  private static func origin(of url: URL) -> String? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.path = ""
    components.query = nil
    components.fragment = nil
    if (components.scheme == "http" && components.port == 80) ||
      (components.scheme == "https" && components.port == 443) { components.port = nil }
    return components.string
  }
}
