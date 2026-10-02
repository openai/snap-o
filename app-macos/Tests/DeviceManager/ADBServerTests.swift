import Darwin
import Foundation

func testsADBStartup() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  func executable(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  let sdkADB = try executable("SDK with spaces/platform-tools/adb")
  let pathADB = try executable("bin/adb")
  let customADB = try executable("custom/selected adb")
  let standardADB = try executable("Library/Android/sdk/platform-tools/adb")
  var configuration = [
    "ANDROID_HOME": sdkADB.deletingLastPathComponent().deletingLastPathComponent().path,
    "PATH": pathADB.deletingLastPathComponent().path
  ]
  func resolved() throws -> URL {
    try ADBServer(home: root, environment: configuration).resolveExecutable()
  }
  try expect(try resolved() == sdkADB, "Explicit SDK must precede default SDK and PATH")
  configuration["ANDROID_HOME"] = nil
  configuration["ANDROID_SDK_ROOT"] = sdkADB.deletingLastPathComponent().deletingLastPathComponent().path
  try expect(try resolved() == sdkADB, "ANDROID_SDK_ROOT must resolve platform-tools")
  configuration["SNAPO_ADB"] = customADB.path
  try expect(try resolved() == customADB, "SNAPO_ADB must precede SDK and PATH")
  configuration["SNAPO_ADB"] = "~/custom/selected adb"
  try expect(try resolved() == customADB, "SNAPO_ADB must expand the user's home")
  configuration["SNAPO_ADB"] = "adb"
  try expect(try resolved() == pathADB, "A named SNAPO_ADB override must resolve from PATH")
  configuration["SNAPO_ADB"] = root.appendingPathComponent("missing").path
  try expectFailure("SNAPO_ADB") { _ = try resolved() }
  configuration["SNAPO_ADB"] = customADB.deletingLastPathComponent().path
  try expectFailure("SNAPO_ADB") { _ = try resolved() }
  configuration["SNAPO_ADB"] = nil
  configuration["ANDROID_SDK_ROOT"] = nil
  try expect(try resolved() == standardADB, "Default Android Studio SDK must work without shell configuration")
  try FileManager.default.removeItem(at: standardADB)
  try expect(try resolved() == pathADB, "Custom PATH must work without an SDK installation")

  var probes = 0
  var server = ADBServer(home: root, environment: ["SNAPO_ADB": customADB.path])
  server.isListening = {
    probes += 1
    return probes == 3
  }
  try server.startIfNeeded()
  let arguments = try String(contentsOf: URL(fileURLWithPath: customADB.path + ".arguments"), encoding: .utf8)
  try expect(arguments == "-L\ntcp:127.0.0.1:5037\nstart-server\n", "Startup must use fixed arguments and the native client's endpoint")
  try expect(probes == 3, "Check before discovery, immediately before launch, and after launch")

  var launches = 0
  server.run = { _, _, _ in launches += 1 }
  server.isListening = { true }
  try server.startIfNeeded()
  try expect(launches == 0, "A running server must never invoke the executable, even with SNAPO_ADB")

  var online = ADBServer(home: root, environment: ["SNAPO_ADB": "/missing/adb"])
  online.isListening = { true }
  try online.startIfNeeded()

  probes = 0
  server.isListening = { probes += 1
    return probes > 1
  }
  try server.startIfNeeded()
  try expect(launches == 0, "A server appearing before launch must be left alone")
  server.isListening = { throw POSIXError(.EACCES) }
  do {
    try server.startIfNeeded()
    throw AndroidHostServiceError(message: "A failed probe must not start ADB")
  } catch is POSIXError {}
  try expect(launches == 0, "An inconclusive probe must never invoke the executable")
  server.isListening = { false }
  try expectFailure("without starting a server") { try server.startIfNeeded() }
  try expect(launches == 1, "A missing server may start once, with no automatic restart loop")

  var redirected = ADBServer(home: root, environment: [
    "SNAPO_ADB": customADB.path,
    "ADB_SERVER_SOCKET": "tcp:remote.invalid:1234",
    "ANDROID_ADB_SERVER_ADDRESS": "remote.invalid",
    "ANDROID_ADB_SERVER_PORT": "1234"
  ])
  probes = 0
  redirected.isListening = { probes += 1
    return probes == 3
  }
  redirected.run = { _, _, environment in
    try expect(environment["ADB_SERVER_SOCKET"] == "tcp:127.0.0.1:5037", "The child must target the native client's endpoint")
    try expect(environment["ANDROID_ADB_SERVER_ADDRESS"] == nil, "An inherited remote address must not redirect startup")
    try expect(environment["ANDROID_ADB_SERVER_PORT"] == nil, "An inherited remote port must not redirect startup")
  }
  try redirected.startIfNeeded()

  var listener = socket(AF_INET, SOCK_STREAM, 0)
  try expect(listener >= 0, "Create synthetic server socket")
  defer { if listener >= 0 { Darwin.close(listener) } }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  try expect(bound == 0, "Bind synthetic server socket")
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let named = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
  }
  try expect(named == 0, "Read synthetic server port")
  let port = UInt16(bigEndian: address.sin_port)
  try expect(listen(listener, 4) == 0, "Listen on synthetic server socket")
  try expect(try ADBServer.isListening(port: port), "A listening server must be detected without sending an ADB command")
  Darwin.close(listener)
  listener = -1
  try expect(try !ADBServer.isListening(port: port), "Connection refusal means the server is absent")
  print("ADB startup tests passed (existing server, races, errors, custom paths, and local endpoint)")
}
