import Foundation

/// Accessed only on EmulatorService's serial worker queue.
final class EmulatorHost {
  private struct Launch {
    let process: Process
    let startedAt: Date
  }

  private let moveToTrash: (URL) throws -> URL
  private let consolePath: (String) throws -> String
  private let stopConsole: (String, String) throws -> Void
  private let home: URL
  private let environment: [String: String]
  private var launches: [String: Launch] = [:]
  private var failures: [String: String] = [:]
  private var stopping: Set<String> = []

  init(
    home: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    moveToTrash: @escaping (URL) throws -> URL = EmulatorHost.trash,
    consolePath: ((String) throws -> String)? = nil,
    stopConsole: ((String, String) throws -> Void)? = nil
  ) {
    let path = getpwuid(getuid()).flatMap(\.pointee.pw_dir).map { String(cString: $0) } ?? NSHomeDirectory()
    self.moveToTrash = moveToTrash
    self.home = home ?? URL(fileURLWithPath: path)
    self.environment = environment
    let console = EmulatorConsole(home: self.home)
    self.consolePath = consolePath ?? { try console.path(serial: $0) }
    self.stopConsole = stopConsole ?? { try console.stop(serial: $0, expectedPath: $1) }
  }

  private var avdHome: URL {
    if let path = environment["ANDROID_AVD_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
    let androidHome = environment["ANDROID_USER_HOME"].map { URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".android")
    return androidHome.appendingPathComponent("avd")
  }

  private func sdk(requiring executable: String = "emulator/emulator") throws -> URL {
    let candidates: [String?] = [
      environment["ANDROID_HOME"],
      environment["ANDROID_SDK_ROOT"],
      home.appendingPathComponent("Library/Android/sdk").path
    ]
    for path in candidates.compactMap(\.self) where !path.isEmpty {
      let directory = URL(fileURLWithPath: path)
      if FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(executable).path) {
        return directory
      }
    }
    let message = executable == "platform-tools/adb"
      ? "Install Android SDK Platform Tools to start the ADB server."
      : "Android SDK not found. Install the Emulator package in ~/Library/Android/sdk."
    throw EmulatorServiceError(message: message)
  }

  func startADBServer() throws {
    let adb = try sdk(requiring: "platform-tools/adb").appendingPathComponent("platform-tools/adb")
    _ = try EmulatorCommand(executable: adb, arguments: ["start-server"]).run()
  }

  func controls(serial: String) throws -> EmulatorControls {
    try EmulatorConsole(home: home).controls(serial: serial) { try self.displaySize(serial: serial) }
  }

  private func displaySize(serial: String) throws -> String {
    let adb = try sdk(requiring: "platform-tools/adb").appendingPathComponent("platform-tools/adb")
    let timeoutMessage = "The emulator did not respond while Snap-O was reading its display. Check that it is running, then try again."
    let size = try EmulatorCommand(executable: adb, arguments: ["-s", serial, "shell", "wm", "size"]).run(timeoutMessage: timeoutMessage)
    let display = try EmulatorCommand(executable: adb, arguments: ["-s", serial, "shell", "dumpsys", "display"])
      .run(timeoutMessage: timeoutMessage)
    return size + "\n" + display
  }

  func control(serial: String, avdPath: String, action: String) throws {
    guard let action = EmulatorControlAction(rawValue: action) else {
      throw EmulatorServiceError(message: "Unknown emulator control.")
    }
    try EmulatorConsole(home: home).control(
      serial: serial, expectedPath: avdPath, action: action,
      displaySize: { try self.displaySize(serial: serial) },
      rotateDisplay: { quarterTurns in
        let adb = try self.sdk(requiring: "platform-tools/adb").appendingPathComponent("platform-tools/adb")
        try EmulatorDisplayRotation { arguments in
          try EmulatorCommand(executable: adb, arguments: ["-s", serial, "shell"] + arguments).run(
            timeoutMessage: "The emulator did not respond to the rotation request. Check that it is running, then try again."
          )
        }.rotate(quarterTurns: quarterTurns)
      }
    )
  }

  func snapshot(serials: [String]) throws -> EmulatorInventory {
    var devices = try configurations(sdk: sdk())
    for serial in Set(serials) {
      guard let path = try? consolePath(serial), !path.isEmpty else { continue }
      let id = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
      guard let index = devices.firstIndex(where: { $0.id == id }) else { continue }
      devices[index].serial = serial
      // Connection and boot state are supplied by the app's native ADB client.
      devices[index].state = .offline
      devices[index].detail = nil
    }
    for index in devices.indices {
      let id = devices[index].id
      if let launch = launches[id] {
        if launch.process.isRunning {
          if devices[index].serial == nil { devices[index].state = .starting }
          if devices[index].state == .starting, Date().timeIntervalSince(launch.startedAt) > 180 {
            devices[index].detail = "Startup is taking longer than expected. Check the emulator log."
          }
        } else {
          if launch.process.terminationStatus != 0, !stopping.contains(id) {
            failures[id] = "Emulator exited with code \(launch.process.terminationStatus)."
          }
          launches.removeValue(forKey: id)
        }
      }
      let isLocked = hasLock(devices[index])
      if devices[index].serial == nil, devices[index].state == .stopped, isLocked {
        devices[index].state = .unavailable
        devices[index].detail = "This AVD is in use or has a leftover lock. Waiting for its emulator connection."
      }
      if stopping.contains(id) {
        if devices[index].serial != nil || launches[id]?.process.isRunning == true || isLocked {
          devices[index].state = .stopping
          devices[index].detail = nil
        } else {
          stopping.remove(id)
        }
      }
      if devices[index].serial == nil, let failure = failures[id] { devices[index].detail = failure }
    }
    return EmulatorInventory(devices: devices)
  }

  func start(_ id: String, coldBoot: Bool, serials: [String]) throws -> EmulatorInventory {
    var inventory = try snapshot(serials: serials)
    guard let device = inventory.devices.first(where: { $0.id == id }) else {
      throw EmulatorServiceError(message: "This emulator no longer exists. Refresh the list.")
    }
    if device.serial != nil {
      guard coldBoot else { throw EmulatorServiceError(message: "This emulator is already running.") }
      _ = try stop(id, serial: device.serial ?? "")
      let deadline = Date().addingTimeInterval(20)
      repeat {
        Thread.sleep(forTimeInterval: 0.3)
        inventory = try snapshot(serials: serials)
        if inventory.devices.first(where: { $0.id == id })?.canStart == true { break }
      } while Date() < deadline
    }
    guard inventory.devices.first(where: { $0.id == id })?.canStart == true else {
      throw EmulatorServiceError(message: "This AVD is still in use. Wait for it to stop before starting it.")
    }
    failures.removeValue(forKey: id)
    let sdk = try sdk()
    let logDirectory = home.appendingPathComponent("Library/Logs/Snap-O/Emulators")
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let logURL = logDirectory.appendingPathComponent(device.avdName + ".log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    let process = Process()
    process.executableURL = sdk.appendingPathComponent("emulator/emulator")
    let config = properties(at: URL(fileURLWithPath: device.id).appendingPathComponent("config.ini"))
    let isResizable = config["hw.device.name"] == "resizable" || !(config["hw.resizable.configs"] ?? "").isEmpty
    // Display-mode switching requires the UI backend, even when its window is hidden.
    let windowOption = isResizable ? "-qt-hide-window" : "-no-window"
    process.arguments = ["-avd", device.avdName, windowOption, "-grpc-use-token"] + (coldBoot ? ["-no-snapshot-load"] : [])
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    try process.run()
    launches[id] = Launch(process: process, startedAt: Date())
    return try snapshot(serials: serials)
  }

  func stop(_ id: String, serial: String) throws -> EmulatorInventory {
    let inventory = try snapshot(serials: [serial])
    guard let device = inventory.devices.first(where: { $0.id == id }), device.serial == serial else {
      throw EmulatorServiceError(message: "The emulator is not connected yet. Wait for startup, then try again.")
    }
    try stopConsole(serial, id)
    failures.removeValue(forKey: id)
    stopping.insert(id)
    var devices = inventory.devices
    if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].state = .stopping }
    return EmulatorInventory(devices: devices)
  }

  func delete(_ id: String, serials: [String]) throws -> EmulatorInventory {
    let inventory = try snapshot(serials: serials)
    guard let device = inventory.devices.first(where: { $0.id == id }) else {
      throw EmulatorServiceError(message: "This emulator no longer exists. Refresh the list.")
    }
    guard device.canDelete, !hasLock(device), launches[id]?.process.isRunning != true else {
      throw EmulatorServiceError(message: "Stop the emulator before deleting it.")
    }
    let directory = URL(fileURLWithPath: device.id)
    guard directory.pathExtension == "avd",
          directory != avdHome.standardizedFileURL.resolvingSymlinksInPath(),
          FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.ini").path) else {
      throw EmulatorServiceError(message: "The AVD folder could not be verified. Reveal it in Finder to inspect it.")
    }
    let configuration = avdHome.appendingPathComponent(device.avdName + ".ini")
    let trashedDirectory = try moveToTrash(directory)
    do {
      _ = try moveToTrash(configuration)
    } catch {
      do {
        try FileManager.default.moveItem(at: trashedDirectory, to: directory)
      } catch {
        throw EmulatorServiceError(message: "The AVD folder is in Trash, but its configuration could not be removed.")
      }
      throw error
    }
    failures.removeValue(forKey: id)
    stopping.remove(id)
    // Report the mutation even if the next SDK discovery temporarily fails.
    return EmulatorInventory(devices: inventory.devices.filter { $0.id != id })
  }

  static func trash(_ url: URL) throws -> URL {
    var destination: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
    guard let destination else { throw EmulatorServiceError(message: "Could not locate the AVD in Trash.") }
    return destination as URL
  }

  private func configurations(sdk: URL) throws -> [ManagedEmulator] {
    let names = try EmulatorCommand(executable: sdk.appendingPathComponent("emulator/emulator"), arguments: ["-list-avds"]).run()
    var devices: [ManagedEmulator] = []
    for name in names.split(whereSeparator: \.isNewline).map(String.init) {
      guard !name.isEmpty,
            name.unicodeScalars
            .allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) })
      else { continue }
      let ini = properties(at: avdHome.appendingPathComponent(name + ".ini"))
      let path = ini["path"].map { URL(fileURLWithPath: $0) }
        ?? ini["path.rel"].map { avdHome.deletingLastPathComponent().appendingPathComponent($0) }
        ?? avdHome.appendingPathComponent(name + ".avd")
      let config = properties(at: path.appendingPathComponent("config.ini"))
      let target = ini["target"] ?? "Android"
      devices.append(ManagedEmulator(
        id: path.standardizedFileURL.resolvingSymlinksInPath().path,
        avdName: name,
        title: config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " "),
        platform: target.replacingOccurrences(of: "android-", with: "API "),
        architecture: config["abi.type"] ?? "",
        state: config.isEmpty ? .unavailable : .stopped,
        detail: config.isEmpty ? "The AVD configuration is missing or unreadable." : nil
      ))
    }
    return devices.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  private func properties(at url: URL) -> [String: String] {
    (try? String(contentsOf: url, encoding: .utf8)).map(ManagedEmulator.properties) ?? [:]
  }

  private func hasLock(_ device: ManagedEmulator) -> Bool {
    let folder = URL(fileURLWithPath: device.id)
    return ["hardware-qemu.ini.lock", "userdata-qemu.img.lock"].contains { name in
      let lockURL = folder.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: lockURL.path) else { return false }
      // Emulator lock files contain a NUL-terminated PID and may survive a crash.
      guard let text = try? String(contentsOf: lockURL, encoding: .utf8),
            let token = text.split(whereSeparator: { $0 == "\0" || $0.isWhitespace }).first,
            let pid = Int32(token), pid > 0 else { return true }
      return kill(pid, 0) == 0 || errno != ESRCH
    }
  }
}
