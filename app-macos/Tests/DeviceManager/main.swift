import Foundation

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else { throw EmulatorServiceError(message: message) }
}

func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
  do {
    try operation()
  } catch {
    try expect(error.localizedDescription.contains(message), "Unexpected error: \(error)")
    return
  }
  throw EmulatorServiceError(message: "Expected failure: \(message)")
}

func rejectsDeletingRunningEmulator(_ fixture: HostFixture) throws {
  try expectFailure("Stop the emulator") {
    _ = try fixture.host().delete(fixture.avd.path, serials: ["emulator-5554"])
  }
}

func restoresAVDAfterTrashFailure(_ fixture: HostFixture) throws {
  try expectFailure("Trash unavailable") {
    _ = try fixture.host(failConfigurationTrash: true).delete(fixture.avd.path, serials: [])
  }
  try expect(
    try String(contentsOf: fixture.avd.appendingPathComponent("disk.img"), encoding: .utf8) == "saved data",
    "A failed delete must restore the emulator's data"
  )
}

func preservesDeletedDataInTrash(_ fixture: HostFixture) throws {
  _ = try fixture.host().delete(fixture.avd.path, serials: [])
  try expect(
    try String(contentsOf: fixture.root.appendingPathComponent("trash/Test.avd/disk.img"), encoding: .utf8) == "saved data",
    "Deleted emulator data must remain recoverable from Trash"
  )
}

func ignoresDeadProcessLock(_ fixture: HostFixture) throws {
  try fixture.write("avds/Test.avd/hardware-qemu.ini.lock", "2147483647\0")
  try expect(try fixture.host().snapshot(serials: []).devices.first?.canStart == true, "A stale lock must not prevent restarting")
}

struct HostFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var avd: URL {
    root.appendingPathComponent("avds/Test.avd").resolvingSymlinksInPath()
  }

  init() throws {
    try write("avds/Test.ini", "path=\(avd.path)\n")
    try write("avds/Test.avd/config.ini", "avd.ini.displayname=Test\n")
    try write("avds/Test.avd/disk.img", "saved data")
    try write("sdk/emulator/emulator", "#!/bin/sh\nprintf 'Test\\n'\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: root.appendingPathComponent("sdk/emulator/emulator").path
    )
  }

  func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func host(failConfigurationTrash: Bool = false) -> EmulatorHost {
    EmulatorHost(home: root, environment: [
      "ANDROID_HOME": root.appendingPathComponent("sdk").path,
      "ANDROID_AVD_HOME": root.appendingPathComponent("avds").path
    ], moveToTrash: { url in
      if failConfigurationTrash, url.pathExtension == "ini" {
        throw EmulatorServiceError(message: "Trash unavailable")
      }
      let trash = root.appendingPathComponent("trash")
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let destination = trash.appendingPathComponent(url.lastPathComponent)
      try FileManager.default.moveItem(at: url, to: destination)
      return destination
    }, consolePath: { _ in avd.path })
  }
}

for test in [rejectsDeletingRunningEmulator, restoresAVDAfterTrashFailure, preservesDeletedDataInTrash, ignoresDeadProcessLock] {
  let fixture = try HostFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try test(fixture)
}

try runConsoleTests()
print("Emulator helper tests passed (7 tests)")
