import Darwin
import Foundation
@testable import Snap_O
import Testing

@Suite("Device file transfers")
struct ADBFileTransferTests {
  @Test("uploads preserve bytes and sync framing", arguments: [0, 200_003])
  func uploads(size: Int) async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: source) }
    let contents = Data((0 ..< size).map { UInt8($0 % 251) })
    try contents.write(to: source)
    let server = try UploadPeer()
    defer { server.close() }
    let path = "/sdcard/Download/a 'quoted' 文.txt"
    async let received = server.receive()
    try await server.client.uploadFile(deviceID: "synthetic-device", localURL: source, remotePath: path) { _ in }
    let result = try await received
    #expect(result.path == path + ",33188")
    #expect(result.data == contents)
  }

  @Test("a device write failure is reported")
  func uploadFailure() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: source) }
    try Data("sample".utf8).write(to: source)
    let server = try UploadPeer()
    defer { server.close() }
    async let received = server.receive(failure: "No space left on device")
    await #expect(throws: (any Error).self) {
      try await server.client.uploadFile(deviceID: "synthetic-device", localURL: source, remotePath: "/sample") { _ in }
    }
    _ = try await received
  }

  @Test("shell output requires a successful final status")
  func checkedOutput() throws {
    #expect(try DeviceFileCommand.result("Success\n\nSNAPO_FILE_EXIT:0\r\n") == "Success")
    #expect(throws: (any Error).self) { try DeviceFileCommand.result("Success") }
    #expect(throws: (any Error).self) { try DeviceFileCommand.result("Permission denied\nSNAPO_FILE_EXIT:1\n") }
    #expect(DeviceFileCommand.quote("a'b;$(echo no)") == "'a'\\''b;$(echo no)'")
  }

  @Test("cancellation interrupts a stalled upload acknowledgment")
  func cancellation() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: source) }
    try Data("sample".utf8).write(to: source)
    let server = try UploadPeer()
    defer { server.close() }
    let task = Task {
      try await server.client.uploadFile(deviceID: "synthetic-device", localURL: source, remotePath: "/sample") { _ in }
    }
    _ = try await server.receive(acknowledge: false)
    let start = ContinuousClock.now
    task.cancel()
    do {
      try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(start.duration(to: .now) < .seconds(1))
  }

  @Test("APK drops prompt once and keep mixed files together")
  @MainActor
  func apkPrompt() async throws {
    let device = Device(id: "synthetic", model: "Test phone", androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
    let model = DeviceFileDrop(device: device)
    let apk = URL(fileURLWithPath: "/tmp/synthetic.apk")
    let text = URL(fileURLWithPath: "/tmp/synthetic.txt")
    #expect(model.receive([NSItemProvider(object: apk as NSURL), NSItemProvider(object: text as NSURL)]))
    #expect(!model.canAcceptDrop)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while model.isBusy, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.asksToInstall)
    #expect(model.pendingFiles == [apk, text])
    #expect(model.installMessage == "1 other file will copy to Downloads.")
    model.cancel()
    #expect(model.canAcceptDrop)
    #expect(model.pendingFiles.isEmpty)
  }

  @Test("install, update, and open a synthetic APK", .enabled(if: ProcessInfo.processInfo.environment["SNAPO_FILE_TRANSFER_APK"] != nil))
  func emulatorInstall() async throws {
    let device = try #require(ProcessInfo.processInfo.environment["SNAPO_FILE_TRANSFER_DEVICE"])
    guard device.hasPrefix("emulator-") else { return }
    let path = try #require(ProcessInfo.processInfo.environment["SNAPO_FILE_TRANSFER_APK"])
    let url = URL(fileURLWithPath: path)
    let metadata = try APKPackageName.read(from: url)
    let package = try #require(metadata)
    try #require(package == "com.example.snapo.filetransferfixture")
    let adb = ADBClient()
    let existing = try await adb.fileCommand(deviceID: device, command: "pm list packages \(package)")
    try #require(existing.isEmpty, "Do not overwrite an existing fixture app.")
    do {
      let user = try await adb.installAPK(deviceID: device, localURL: url) { _ in }
      #expect(try await adb.installAPK(deviceID: device, localURL: url) { _ in } == user)
      try await adb.openApp(deviceID: device, packageName: package, androidUserID: user)
      _ = try await adb.fileCommand(deviceID: device, command: "pm uninstall \(package)")
    } catch {
      _ = try? await adb.fileCommand(deviceID: device, command: "pm uninstall \(package)")
      throw error
    }
  }

  @Test("copy names preserve extensions and reject invalid paths")
  func copyNames() throws {
    #expect(try DeviceFileCommand.filename("photo.jpg", copy: 2) == "photo (2).jpg")
    #expect(try DeviceFileCommand.filename("README", copy: 1) == "README (1)")
    for name in ["", ".", "..", "../file", "line\nbreak"] {
      #expect(throws: (any Error).self) { try DeviceFileCommand.filename(name) }
    }
  }

  @Test("file-transfer policy checks only the target user's effective restrictions")
  func fileTransferPolicy() {
    let dump = """
    Users:
      UserInfo{0:Test:123} serialNo=0
        Restrictions:
          no_add_user
        Effective restrictions:
          no_usb_file_transfer
          no_add_user
        Account name: null
      UserInfo{10:Other:456} serialNo=10
        Effective restrictions:
          no_add_user
        Account name: null
    Guest restrictions:
      no_usb_file_transfer
    """
    #expect(DeviceFileCommand.blocksFileTransfers(dump, user: 0))
    #expect(!DeviceFileCommand.blocksFileTransfers(dump, user: 10))
    #expect(!DeviceFileCommand.blocksFileTransfers(dump, user: 11))
    #expect(!DeviceFileCommand.blocksFileTransfers("Permission denied", user: 0))
  }

  @Test(
    "managed device reports its file-transfer policy",
    .enabled(if: ProcessInfo.processInfo.environment["SNAPO_RESTRICTED_DEVICE"] != nil)
  )
  func restrictedDevice() async throws {
    let device = try #require(ProcessInfo.processInfo.environment["SNAPO_RESTRICTED_DEVICE"])
    do {
      _ = try await ADBClient().downloadsDirectory(deviceID: device)
      Issue.record("Expected a file-transfer policy denial")
    } catch DeviceFileTransferError.blockedByPolicy {}
  }

  @Test("binary manifests support both string encodings", arguments: [false, true])
  func packageName(utf8: Bool) {
    let fixture = manifest(utf8: utf8)
    #expect(APKPackageName.parse(fixture) == "com.example.synthetic")
    for end in 0 ..< fixture.count {
      #expect(APKPackageName.parse(fixture.prefix(end)) == nil)
    }
  }

  @Test(
    "copying on an explicitly selected emulator",
    .enabled(if: ProcessInfo.processInfo.environment["SNAPO_FILE_TRANSFER_DEVICE"] != nil)
  )
  func emulatorCopy() async throws {
    let device = try #require(ProcessInfo.processInfo.environment["SNAPO_FILE_TRANSFER_DEVICE"])
    #expect(device.hasPrefix("emulator-"))
    guard device.hasPrefix("emulator-") else { return }
    let adb = ADBClient()
    let downloads = try await adb.downloadsDirectory(deviceID: device)
    let directory = downloads + "/snap-o-test-" + UUID().uuidString
    _ = try await adb.fileCommand(deviceID: device, command: "mkdir \(DeviceFileCommand.quote(directory))")
    let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: local) }
    do {
      let original = Data("Synthetic transfer fixture.\n".utf8)
      try original.write(to: local)
      let remote = directory + "/a 'quoted' 文.txt"
      #expect(try await adb.copyFile(deviceID: device, localURL: local, destination: remote, replace: false) { _ in } == nil)
      #expect(try await adb.fileExists(deviceID: device, path: remote))
      let read = try await adb.fileCommand(deviceID: device, command: "cat \(DeviceFileCommand.quote(remote))")
      #expect(read == "Synthetic transfer fixture.")
      try Data("Replacement".utf8).write(to: local)
      await #expect(throws: (any Error).self) {
        _ = try await adb.copyFile(deviceID: device, localURL: local, destination: remote, replace: false) { _ in }
      }
      #expect(try await adb.fileCommand(deviceID: device, command: "cat \(DeviceFileCommand.quote(remote))") == read)
      _ = try await adb.copyFile(deviceID: device, localURL: local, destination: remote, replace: true) { _ in }
      #expect(try await adb.fileCommand(deviceID: device, command: "cat \(DeviceFileCommand.quote(remote))") == "Replacement")
      try Data().write(to: local)
      _ = try await adb.copyFile(deviceID: device, localURL: local, destination: directory + "/empty", replace: false) { _ in }
      let listing = try await adb.fileCommand(deviceID: device, command: "ls -A \(DeviceFileCommand.quote(directory))")
      #expect(!listing.contains(".partial"))
      await #expect(throws: (any Error).self) {
        _ = try await adb.installAPK(deviceID: device, localURL: local) { _ in }
      }
      _ = try await adb.fileCommand(deviceID: device, command: "rm -r \(DeviceFileCommand.quote(directory))")
    } catch {
      _ = try? await adb.fileCommand(deviceID: device, command: "rm -r \(DeviceFileCommand.quote(directory))")
      throw error
    }
  }

  private func manifest(utf8: Bool) -> Data {
    let strings = ["manifest", "package", "com.example.synthetic"]
    var pool = Data()
    var offsets = Data()
    for string in strings {
      offsets.append(word(UInt32(pool.count)))
      if utf8 {
        pool.append(contentsOf: [UInt8(string.count), UInt8(string.utf8.count)])
        pool.append(Data(string.utf8))
        pool.append(0)
      } else {
        pool.append(contentsOf: [UInt8(string.count), 0])
        pool.append(string.data(using: .utf16LittleEndian) ?? Data())
        pool.append(contentsOf: [0, 0])
      }
    }
    while pool.count % 4 != 0 {
      pool.append(0)
    }
    var stringChunk = Data([1, 0, 28, 0])
    stringChunk.append(word(UInt32(28 + offsets.count + pool.count)))
    for value: UInt32 in [3, 0, utf8 ? 256 : 0, 40, 0] {
      stringChunk.append(word(value))
    }
    stringChunk.append(offsets)
    stringChunk.append(pool)
    var element = Data([2, 1, 16, 0])
    for value: UInt32 in [56, 1, UInt32.max, UInt32.max, 0] {
      element.append(word(value))
    }
    element.append(contentsOf: [20, 0, 20, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    for value: UInt32 in [UInt32.max, 1, 2, 0x0300_0008, 2] {
      element.append(word(value))
    }
    var xml = Data([3, 0, 8, 0])
    xml.append(word(UInt32(8 + stringChunk.count + element.count)))
    xml.append(stringChunk)
    xml.append(element)
    return xml
  }
}

private func word(_ value: UInt32) -> Data {
  var number = value.littleEndian
  return withUnsafeBytes(of: &number) { Data($0) }
}

private final class UploadPeer: @unchecked Sendable {
  let client: ADBClient
  private let peer: ADBSocketConnection
  private let connection: ADBSocketConnection

  init() throws {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
    connection = ADBSocketConnection(connectedSocket: sockets[0])
    peer = ADBSocketConnection(connectedSocket: sockets[1])
    let connection = connection
    client = ADBClient(discoveryTimeout: .seconds(2), connectionFactory: { connection })
  }

  func close() {
    connection.close()
    peer.close()
  }

  func receive(failure: String? = nil, acknowledge: Bool = true) async throws -> (path: String, data: Data) {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { [self] in
        continuation.resume(with: Result {
          try peer.withRequestTimeout(.seconds(5)) {
            for expected in ["host:transport:synthetic-device", "sync:"] {
              let request = try peer.readLengthPrefixedPayload()
              #expect(request == Data(expected.utf8))
              try peer.writeFully(Data("OKAY".utf8))
            }
            #expect(try read(4) == Data("SEND".utf8))
            let path = try String(decoding: read(length()), as: UTF8.self)
            var contents = Data()
            while true {
              let kind = try read(4)
              let size = try length()
              if kind == Data("DONE".utf8) { break }
              #expect(kind == Data("DATA".utf8))
              guard size <= 65536 else { throw POSIXError(.EIO) }
              try contents.append(read(size))
            }
            if !acknowledge { return (path, contents) }
            if let failure {
              try peer.writeFully(Data("FAIL".utf8) + word(UInt32(failure.utf8.count)) + Data(failure.utf8))
            } else {
              try peer.writeFully(Data("OKAY".utf8) + word(0))
            }
            return (path, contents)
          }
        })
      }
    }
  }

  private func length() throws -> Int {
    let data = try [UInt8](read(4))
    return Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
  }

  private func read(_ count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
      guard let chunk = try peer.readChunk(maxLength: count - data.count) else { throw POSIXError(.EIO) }
      data.append(chunk)
    }
    return data
  }
}
