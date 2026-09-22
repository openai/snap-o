import Darwin
import Foundation

private final class ConsoleFixture: @unchecked Sendable {
  let client: Int32
  let peer: Int32
  let finished = DispatchGroup()
  let byteDelay: TimeInterval
  private var commands: [String] = []

  init(greeting: String, byteDelay: TimeInterval = 0, respond: @escaping @Sendable (String) -> String) throws {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      throw EmulatorServiceError(message: "socketpair failed")
    }
    self.byteDelay = byteDelay
    client = sockets[0]
    peer = sockets[1]
    var enabled: Int32 = 1
    setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    finished.enter()
    DispatchQueue.global().async { [self] in
      defer { Darwin.close(peer)
        finished.leave()
      }
      send(greeting)
      var line = ""
      var byte: UInt8 = 0
      while recv(peer, &byte, 1, 0) == 1 {
        if byte == 10 {
          commands.append(line)
          send(respond(line))
          line = ""
        } else { line.append(Character(UnicodeScalar(byte))) }
      }
    }
  }

  private func send(_ text: String) {
    for byte in text.utf8 {
      var byte = byte
      if Darwin.send(peer, &byte, 1, 0) != 1 { return }
      if byteDelay > 0 { Thread.sleep(forTimeInterval: byteDelay) }
    }
  }

  func recorded() -> [String] {
    finished.wait()
    return commands
  }
}

func runConsoleTests() throws {
  try authenticatesBeforeShutdown()
  try refusesToStopAnotherAVD()
  try limitsResponseTime()
  try detectsSupportedControls()
  try readsCurrentPosture()
  try dispatchesEmulatorControls()
  try refusesUnsupportedControls()
  try refusesControlsForAnotherAVD()
  try reportsControlFailure()
  try detectsLiveDisplayModes()
  try filtersDisplayModesByRuntimeSupport()
  try detectsFoldableModeWhileClosed()
  try rejectsMalformedDisplayPresets()
  try dispatchesDisplayMode()
  try sendsModeAfterSlowDisplayRead()
  try recoversUnappliedDisplayMode()
  try boundsDisplayModeRecovery()
}

private let resizableProperties = [
  "hw.device.name": "resizable", "hw.sensor.hinge": "true", "hw.sensor.posture_list": "1, 2, 3",
  "hw.resizable.configs": "phone-0-1080-2400-420, foldable-1-2208-1840-420, tablet-2-1920-1200-240, desktop-3-1920-1080-160",
  "hw.lcd.width": "1080", "hw.lcd.height": "2400"
]

private func readsCurrentPosture() throws {
  let fixture = try HostFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.write("avds/Test.avd/config.ini", """
  hw.sensor.hinge=true
  hw.sensor.hinge.count=1
  hw.sensor.posture_list=1, 2, 3
  hw.sensor.hinge_angles_posture_definitions=0-10, 10-170, 170-180
  """)
  let path = fixture.avd.path
  let cases: [(Double?, EmulatorControlAction?)] = [(0, .closed), (20, .halfOpen), (180, .open), (nil, nil)]
  for (angle, expected) in cases {
    let server = try ConsoleFixture(greeting: "OK\r\n") { command in
      switch command {
      case "avd path": "\(path)\r\nOK\r\n"
      case "help": "rotate\r\nposture\r\nOK\r\n"
      default: angle.map { "hinge-angle0 = \($0)\r\nOK\r\n" } ?? "KO: sensor unavailable\r\n"
      }
    }
    let controls = try EmulatorConsole(home: fixture.root) { _ in server.client }.controls(serial: "emulator-5554")
    try expect(controls.currentPosture == expected, "Read current posture using the AVD's angle ranges")
    _ = server.recorded()
  }
}

private func detectsLiveDisplayModes() throws {
  let cases: [(String?, EmulatorControlAction?)] = [
    (nil, .phone), ("Physical size: 1080x2400", .phone),
    ("Physical size: 1840x2208\nOverride size: 1000x1000", .foldable), ("unavailable", nil)
  ]
  for (size, expected) in cases {
    let controls = resizableControls(displaySize: size)
    try expect(controls.currentDisplayMode == expected, "Detect the physical display mode from \(size ?? "startup configuration")")
    try expect(controls.postures.isEmpty == (expected != .foldable), "Only Foldable mode offers posture changes")
  }
}

private func filtersDisplayModesByRuntimeSupport() throws {
  let runtime = resizableControls(
    displaySize: "DisplayDeviceInfo{Screen, 1080 x 2400, modeId 1, "
      + "supportedModes [{id=1, width=1080, height=2400}, {id=2, width=2208, height=1840}], address {port=0, model=1}}"
  )
  try expect(runtime.displayModes.map(\.action) == [.phone, .foldable], "Hide configured presets missing from the system image")
}

private func detectsFoldableModeWhileClosed() throws {
  let closed = resizableControls(
    displaySize: "Physical size: 1080x2092\nDisplayDeviceInfo{Inner, 2208 x 1840, modeId 2, "
      + "supportedModes [{id=1, width=1080, height=2400}, {id=2, width=2208, height=1840}], address {port=0, model=1}, state OFF}"
  )
  try expect(
    closed.currentDisplayMode == .foldable && closed.actions.contains(.open),
    "The closed cover display must not hide the Open control or mode menu"
  )
}

private func rejectsMalformedDisplayPresets() throws {
  let parsed = EmulatorDisplayMode.parse("bad,phone-0-1080-2400-420,duplicate-0-10-20-30,unknown-9-1-2-3,tablet-2-0-1200-240")
  try expect(parsed.count == 1 && parsed.first?.action == .phone, "Reject unknown, duplicate, and invalid presets")
}

private func resizableControls(displaySize: String?) -> EmulatorControls {
  EmulatorControls(
    avdPath: "/Resizable.avd",
    commands: "rotate\nposture\nresize-display",
    properties: resizableProperties,
    displaySize: displaySize
  )
}

private func dispatchesDisplayMode() throws {
  try withResizableConsole { console, path, server in
    var queries = 0
    try console.control(
      serial: "emulator-5554", expectedPath: path, action: .foldable,
      displaySize: {
        queries += 1
        return queries < 3 ? "Physical size: 1080x2400" : "Physical size: 2208x1840"
      }, rotateDisplay: { _ in fatalError("Mode selection must not rotate") }
    )
    try expect(server.recorded() == ["avd path", "help", "resize-display 1"], "Validate identity and capabilities before resizing")
    try expect(queries == 3, "Wait for the display to change before reconnecting the stream")
  }
}

private func sendsModeAfterSlowDisplayRead() throws {
  try withResizableConsole { console, path, server in
    var console = console
    console.timeout = .milliseconds(100)
    var queries = 0
    try console.control(
      serial: "emulator-5554", expectedPath: path, action: .foldable,
      displaySize: {
        queries += 1
        if queries == 1 { Thread.sleep(forTimeInterval: 0.15) }
        return queries == 1 ? "Physical size: 1080x2400" : "Physical size: 2208x1840"
      }, rotateDisplay: { _ in }
    )
    try expect(server.recorded().last == "resize-display 1", "Display queries must not consume the next console command's timeout")
  }
}

private func recoversUnappliedDisplayMode() throws {
  try withResizableConsole { console, path, server in
    var console = console
    console.displayChangeTimeout = 0
    var queries = 0
    try console.control(
      serial: "emulator-5554", expectedPath: path, action: .foldable,
      displaySize: {
        queries += 1
        return queries < 4 ? "Physical size: 1080x2400" : "Physical size: 2208x1840"
      }, rotateDisplay: { _ in }
    )
    try expect(
      server.recorded().suffix(3) == ["resize-display 1", "resize-display 0", "resize-display 1"],
      "Recover through the previously confirmed mode before retrying the target"
    )
  }
}

private func boundsDisplayModeRecovery() throws {
  try withResizableConsole { console, path, server in
    var console = console
    console.displayChangeTimeout = 0
    try expectFailure("Android did not apply") {
      try console.control(
        serial: "emulator-5554", expectedPath: path, action: .foldable,
        displaySize: { "Physical size: 1080x2400" }, rotateDisplay: { _ in }
      )
    }
    try expect(
      server.recorded() == ["avd path", "help", "resize-display 1", "resize-display 0", "resize-display 1"],
      "Stop after one recovery and report failure if Android still has not changed modes"
    )
  }
}

private func withResizableConsole(_ body: (EmulatorConsole, String, ConsoleFixture) throws -> Void) throws {
  let fixture = try HostFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.write("avds/Test.avd/config.ini", resizableProperties.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
  let path = fixture.avd.path
  let server = try ConsoleFixture(greeting: "OK\r\n") { command in
    switch command {
    case "avd path": "\(path)\r\nOK\r\n"
    case "help": "rotate\r\nposture\r\nresize-display\r\nOK\r\n"
    default: "OK\r\n"
    }
  }
  var console = EmulatorConsole(home: fixture.root) { _ in server.client }
  console.sleep = { _ in }
  try body(console, path, server)
}

private func detectsSupportedControls() throws {
  let commands = "Android console commands:\n    rotate\n    posture\n    fold\n    unfold\n"
  let phone = EmulatorControls(avdPath: "/Phone.avd", commands: commands, properties: [:])
  try expect(phone.actions == [.rotateLeft, .rotateRight], "A phone must not expose fold controls just because its console has them")
  let properties = ["hw.sensor.hinge": "true", "hw.sensor.posture_list": "1, 3, 5"]
  let foldable = EmulatorControls(avdPath: "/Fold.avd", commands: commands, properties: properties)
  try expect(foldable.postures == [.closed, .open], "Only configured postures should be offered")
  let older = EmulatorControls(avdPath: "/Fold.avd", commands: "rotate\nfold\nunfold", properties: properties)
  try expect(older.actions == [.rotateLeft, .rotateRight], "Postures require console support")
  let malformed = EmulatorControls(avdPath: "/Fold.avd", commands: commands, properties: [
    "hw.sensor.hinge": "yes", "hw.sensor.posture_list": "unknown, 2, 99"
  ])
  try expect(malformed.actions == [.rotateLeft, .rotateRight, .halfOpen], "Unknown posture identifiers must be ignored")
  let unsupported = EmulatorControls(avdPath: "/Resizable.avd", commands: commands, properties: resizableProperties)
  try expect(unsupported.displayModes.isEmpty, "Require console resize support")
}

private func dispatchesEmulatorControls() throws {
  let fixture = try HostFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try fixture.write("avds/Test.avd/config.ini", "hw.sensor.hinge=no\n")
  try fixture.write("avds/Test.avd/hardware-qemu.ini", "hw.sensor.hinge=true\nhw.sensor.posture_list=1, 2, 3\n")
  for (action, command) in [
    (EmulatorControlAction.rotateLeft, ""), (.rotateRight, ""),
    (.closed, "posture 1"), (.halfOpen, "posture 2"), (.open, "posture 3")
  ] {
    let path = fixture.avd.path
    let server = try ConsoleFixture(greeting: "OK\r\n") { command in
      switch command {
      case "avd path": "\(path)\r\nOK\r\n"
      case "help": "    rotate\r\n    posture\r\nOK\r\n"
      default: "OK\r\n"
      }
    }
    var rotation: Int?
    try EmulatorConsole(home: fixture.root) { _ in server.client }
      .control(serial: "emulator-5554", expectedPath: path, action: action) { rotation = $0 }
    let expected = ["avd path", "help"] + (action.isRotation ? [] : [command])
    try expect(server.recorded() == expected, "Verify identity and capabilities before changing the emulator")
    try expect(rotation == (action.isRotation ? action.quarterTurns : nil), "Dispatch the requested rotation direction")
  }
}

private func refusesUnsupportedControls() throws {
  let fixture = try HostFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let path = fixture.avd.path
  for action in [EmulatorControlAction.halfOpen, .foldable] {
    let server = try ConsoleFixture(greeting: "OK\r\n") { command in
      command == "avd path" ? "\(path)\r\nOK\r\n" : "rotate\r\nposture\r\nresize-display\r\nOK\r\n"
    }
    try expectFailure("does not support") {
      try EmulatorConsole(home: fixture.root) { _ in server.client }
        .control(serial: "emulator-5554", expectedPath: path, action: action) { _ in
          fatalError("An unsupported action must not rotate")
        }
    }
    try expect(server.recorded() == ["avd path", "help"], "Never send an unsupported control")
  }
}

private func refusesControlsForAnotherAVD() throws {
  let server = try ConsoleFixture(greeting: "OK\r\n") { _ in "/Other.avd\r\nOK\r\n" }
  try expectFailure("connection changed") {
    try EmulatorConsole(home: FileManager.default.temporaryDirectory) { _ in server.client }
      .control(serial: "emulator-5554", expectedPath: "/Test.avd", action: .rotateRight) { _ in
        fatalError("A replaced emulator must not rotate")
      }
  }
  try expect(server.recorded() == ["avd path"], "A reused serial must not control a different AVD")
}

private func reportsControlFailure() throws {
  let server = try ConsoleFixture(greeting: "OK\r\n") { command in
    switch command {
    case "avd path": "/Test.avd\r\nOK\r\n"
    case "help": "rotate\r\nOK\r\n"
    default: "KO: cannot rotate\r\n"
    }
  }
  try expectFailure("Android refused rotation") {
    try EmulatorConsole(home: FileManager.default.temporaryDirectory) { _ in server.client }
      .control(serial: "emulator-5554", expectedPath: "/Test.avd", action: .rotateRight) { _ in
        throw EmulatorServiceError(message: "Android refused rotation")
      }
  }
  try expect(server.recorded() == ["avd path", "help"], "A rejected action must report failure")
}

private func authenticatesBeforeShutdown() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  try "test-token".write(to: home.appendingPathComponent(".emulator_console_auth_token"), atomically: true, encoding: .utf8)
  let server = try ConsoleFixture(greeting: "Authentication required\r\nOK\r\n") { command in
    command == "avd path" ? "/Test.avd\r\nOK\r\n" : "OK\r\n"
  }
  try EmulatorConsole(home: home) { _ in server.client }.stop(serial: "emulator-5554", expectedPath: "/Test.avd")
  try expect(server.recorded() == ["auth test-token", "avd path", "kill"], "Shutdown must authenticate first")
}

private func refusesToStopAnotherAVD() throws {
  let server = try ConsoleFixture(greeting: "OK\r\n") { _ in "/other.avd\r\nOK\r\n" }
  try? EmulatorConsole(home: FileManager.default.temporaryDirectory) { _ in server.client }
    .stop(serial: "emulator-5554", expectedPath: "/Test.avd")
  try expect(server.recorded() == ["avd path"], "Never send kill after a serial is reused")
}

private func limitsResponseTime() throws {
  let server = try ConsoleFixture(greeting: String(repeating: "x", count: 100), byteDelay: 0.003) { _ in "" }
  defer { _ = server.recorded() }
  try expectFailure("timed out") {
    _ = try EmulatorConsole(home: FileManager.default.temporaryDirectory, connect: { _ in server.client }, timeout: .milliseconds(40))
      .path(serial: "emulator-5554")
  }
}
