import Darwin
import Foundation
@testable import Snap_O
import Testing

/// Run explicitly with TEST_RUNNER_SNAPO_FILE_TRANSFER_INTEGRATION=1 when using xcodebuild.
@Suite("Device file transfer integration", .enabled(if: ProcessInfo.processInfo.environment["SNAPO_FILE_TRANSFER_INTEGRATION"] == "1"))
struct ADBFileTransferIntegrationTests {
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
        try await adb.installAPK(deviceID: device, localURL: local) { _ in }
      }
      _ = try await adb.fileCommand(deviceID: device, command: "rm -r \(DeviceFileCommand.quote(directory))")
    } catch {
      _ = try? await adb.fileCommand(deviceID: device, command: "rm -r \(DeviceFileCommand.quote(directory))")
      throw error
    }
  }
}

private func word(_ value: UInt32) -> Data {
  var number = value.littleEndian
  return withUnsafeBytes(of: &number) { Data($0) }
}

private final class UploadPeer: @unchecked Sendable {
  let client: ADBClient
  private let peer: ADBSocketConnection
  let connection: ADBSocketConnection

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

  func receive(failure: String? = nil) async throws -> (path: String, data: Data) {
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
