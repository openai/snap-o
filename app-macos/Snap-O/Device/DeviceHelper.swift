import CryptoKit
import Foundation

struct DeviceHelper {
  enum Mode {
    case video, pointer, keyboard, clipboard

    var usesShellV2: Bool {
      self == .video || self == .pointer
    }

    fileprivate var arguments: String {
      switch self {
      case .video: "video rgba-fallback rgba-flow-control standby"
      case .pointer: "pointer"
      case .keyboard: "clipboard keyboard"
      case .clipboard: "clipboard"
      }
    }
  }

  private struct CachedBuildUnavailable: Error {}
  struct Session {
    let connection: any ADBConnection
    let stream: ADBShellV2Stream
    let header: Data
  }

  private let bytes: Data
  private let digest: String
  private let legacyDigest: String
  private let buildID: String
  private let identity: Data

  init(_ bytes: Data) throws {
    // The deterministic JAR builder writes the same build ID into Java and the ZIP comment.
    let identity = Data(bytes.suffix(20))
    guard bytes.count <= 128 * 1024, identity.count == 20,
          identity.starts(with: Data("SNHB".utf8)),
          identity.dropFirst(4).allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
          let buildID = String(bytes: identity.dropFirst(4), encoding: .ascii)
    else { throw ADBError.protocolFailure("Invalid device helper build ID") }
    self.bytes = bytes
    self.identity = identity
    self.buildID = buildID
    digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    legacyDigest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  static func bundledBytes() throws -> Data {
    guard let url = Bundle.main.url(forResource: "snapo-device-helper", withExtension: "jar") else {
      throw ADBError.protocolFailure("Missing device helper")
    }
    return try Data(contentsOf: url)
  }

  /// A broken cached build gets one fresh connection and one atomic replacement.
  func connect(_ mode: Mode, serial: String, adb: ADBClient) async throws -> Session {
    for reinstall in [false, true] {
      try Task.checkCancellation()
      let connection = try await adb.makeConnection()
      do {
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
              continuation.resume(with: Result {
                try connection.withRequestTimeout(.seconds(8)) {
                  try connection.sendTransport(to: serial)
                  var stream = ADBShellV2Stream()
                  let header = try launch(mode, on: connection, reinstall: reinstall) { count in
                    if mode.usesShellV2 { return try stream.readExactly(count, read: connection.readChunk) }
                    return try ADBShellV2Stream.readRaw(count, read: connection.readChunk)
                  }
                  return Session(connection: connection, stream: stream, header: header)
                }
              })
            }
          }
        } onCancel: { connection.close() }
      } catch {
        connection.close()
        try Task.checkCancellation()
        guard !reinstall, error is CachedBuildUnavailable else { throw error }
      }
    }
    throw ADBError.protocolFailure("Device helper could not start")
  }

  func launch(
    _ mode: Mode, on connection: any ADBConnection, reinstall: Bool = false, read: (Int) throws -> Data
  ) throws -> Data {
    // The pointer helper handles stdin EOF itself so it can release held contacts.
    let handleHangup = mode == .pointer ? "trap '' HUP" : ""
    let needsInstall = reinstall ? "true" : #"[ ! -f "$jar" ] || [ -L "$jar" ]"#
    let command = """
    exec 2>/dev/null
    umask 077
    cache=/data/local/tmp/snapo-device-helper
    [ ! -L "$cache" ] || exit 1
    jar="$cache/\(digest).jar"
    if \(needsInstall); then
      mkdir -p "$cache" || exit 1
      tmp=$(mktemp "$cache/install.XXXXXX") || exit 1
      trap 'rm -f "$tmp"' EXIT
      trap 'exit 1' HUP INT TERM
      exec 3>"$tmp" && chmod 400 "$tmp" || exit 1
      printf '\\377'
      head -c \(bytes.count) >&3 || {
        # Older Android releases only support line counts in head.
        dd bs=1 count=\(bytes.count) >&3 || exit 1
      }
      exec 3>&-
      if command -v sha256sum >/dev/null; then
        hash=$(sha256sum "$tmp") && [ "${hash%% *}" = "\(digest)" ] || exit 1
      else
        hash=$(sha1sum "$tmp") && [ "${hash%% *}" = "\(legacyDigest)" ] || exit 1
      fi
      mv -f "$tmp" "$jar" || exit 1
    fi
    \(handleHangup)
    CLASSPATH="$jar" exec app_process / com.openai.snapo.Helper \(buildID) \(mode.arguments)
    """
    _ = try connection.sendHostCommand((mode.usesShellV2 ? "shell,v2,raw:" : "exec:") + command, expectsResponse: false)
    var uploaded = false
    do {
      var first = try read(1)
      if first == Data([0xFF]) {
        uploaded = true
        try connection.writeFully(mode.usesShellV2 ? ADBShellV2Stream.standardInput(bytes) : bytes)
        first = try read(1)
      }
      guard first == identity.prefix(1), try first + read(identity.count - 1) == identity else {
        throw ADBError.protocolFailure("Unexpected device helper build")
      }
    } catch {
      if !uploaded, !reinstall { throw CachedBuildUnavailable() }
      throw error
    }
    return try read(4)
  }
}
