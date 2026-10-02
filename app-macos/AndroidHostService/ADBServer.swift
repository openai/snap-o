import Darwin
import Foundation

struct ADBServer {
  let home: URL
  let environment: [String: String]
  var isListening: () throws -> Bool = { try ADBServer.isListening(port: 5037) }
  var run: (URL, [String], [String: String]) throws -> Void = { executable, arguments, environment in
    _ = try EmulatorCommand(executable: executable, arguments: arguments, environment: environment).run()
  }

  init(home: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
    let path = getpwuid(getuid()).flatMap(\.pointee.pw_dir).map { String(cString: $0) } ?? NSHomeDirectory()
    self.home = home ?? URL(fileURLWithPath: path)
    self.environment = environment
  }

  func startIfNeeded() throws {
    // Any listener must be left alone, including a tunnel or an incompatible ADB server.
    guard try !isListening() else { return }
    let executable = try resolveExecutable()
    guard try !isListening() else { return }
    var environment = environment
    environment["ADB_SERVER_SOCKET"] = "tcp:127.0.0.1:5037"
    environment.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
    environment.removeValue(forKey: "ANDROID_ADB_SERVER_PORT")
    try run(executable, ["-L", "tcp:127.0.0.1:5037", "start-server"], environment)
    guard try isListening() else {
      throw AndroidHostServiceError(message: "ADB exited without starting a server on 127.0.0.1:5037.")
    }
  }

  func resolveExecutable() throws -> URL {
    if let configured = environment["SNAPO_ADB"], !configured.isEmpty {
      let candidates = configured.contains("/") ? [expandedPath(configured)] : searchPath(named: configured)
      guard let executable = candidates.first(where: isExecutable) else {
        throw AndroidHostServiceError(message: "SNAPO_ADB does not name an executable file: \(configured)")
      }
      return executable
    }
    let sdkPaths = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap(\.self)
      .filter { !$0.isEmpty }.map { expandedPath($0).appendingPathComponent("platform-tools/adb") }
    let candidates = sdkPaths + [home.appendingPathComponent("Library/Android/sdk/platform-tools/adb")]
      + searchPath(named: "adb") + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"].map { URL(fileURLWithPath: $0) }
    guard let executable = candidates.first(where: isExecutable) else {
      throw AndroidHostServiceError(
        message: "ADB was not found. Install Android SDK Platform Tools, or set SNAPO_ADB to the full path of adb before launching Snap-O."
      )
    }
    return executable
  }

  private func expandedPath(_ path: String) -> URL {
    path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
  }

  private func searchPath(named name: String) -> [URL] {
    (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map {
      URL(fileURLWithPath: String($0)).appendingPathComponent(name)
    }
  }

  private func isExecutable(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
      && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
  }

  static func isListening(port: UInt16) throws -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw failure(errno) }
    defer { Darwin.close(descriptor) }
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw failure(errno) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected == 0 { return true }
    let code = errno
    if code == ECONNREFUSED { return false }
    guard code == EINPROGRESS else { throw failure(code) }
    var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    let result = poll(&event, 1, 1000)
    guard result > 0 else { throw failure(result == 0 ? ETIMEDOUT : errno) }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw failure(errno) }
    if error == ECONNREFUSED { return false }
    guard error == 0 else { throw failure(error) }
    return true
  }

  private static func failure(_ code: Int32) -> AndroidHostServiceError {
    AndroidHostServiceError(message: "Could not check the local ADB server: \(String(cString: strerror(code)))")
  }
}
