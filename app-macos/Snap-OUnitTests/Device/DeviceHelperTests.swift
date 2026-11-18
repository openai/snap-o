import CoreMedia
import CryptoKit
import Foundation
import Testing

enum TestDeviceHelper {
  static let identity = Data("SNHB0123456789abcdef".utf8)
  static let jar = Data("synthetic jar".utf8) + identity

  static func shellHeader(_ version: UInt8) -> Data {
    Data([1, 24, 0, 0, 0]) + identity + Data([0, 0, 0, version])
  }
}

struct DeviceHelperTests {
  @Test(arguments: [false, true])
  func repairsAnUnreadableOrDifferentCachedBuildOnce(unreadable: Bool) async throws {
    let stale = ScriptedADBConnection(reads: unreadable ? [.end] : [.data(Data("SNHBffffffffffffffff".utf8))])
    let good = ScriptedADBConnection(reads: [.data(Data([0xFF]) + TestDeviceHelper.identity + Data([0, 0, 0, 2]))])
    let adb = ADBClient(discoveryTimeout: .seconds(1)) { stale.isClosed ? good : stale }
    let transport = try await DeviceKeyboardTransport.connect(serial: "phone", adb: adb) { TestDeviceHelper.jar }
    defer { transport.close() }
    #expect(stale.isClosed && stale.written.isEmpty)
    #expect(good.commands.last?.contains("if true; then") == true)
    #expect(good.written == TestDeviceHelper.jar)
  }

  @Test(arguments: [
    DeviceHelper.Mode.video,
    .clock,
    .audio(.playback),
    .audio(.microphone),
    .audio(.both),
    .pointer,
    .keyboard,
    .clipboard
  ], [false, true])
  func transmitsTheJarOnlyOnRequest(mode: DeviceHelper.Mode, upload: Bool) throws {
    let jar = TestDeviceHelper.jar
    let helper = try DeviceHelper(jar)
    let header = switch mode {
    case .video: Data("SNV1".utf8)
    case .clock: DeviceClock.magic
    case .audio: Data("SNA1".utf8)
    case .keyboard: Data([0, 0, 0, 2])
    default: Data([0, 0, 0, 1])
    }
    let payload = (upload ? Data([0xFF]) : Data()) + TestDeviceHelper.identity + header + Data([42])
    let wire = mode.usesShellV2 ? Data([1, UInt8(payload.count), 0, 0, 0]) + payload : payload
    let connection = ScriptedADBConnection(reads: [.data(wire)])
    var stream = ADBShellV2Stream()
    func read(_ count: Int) throws -> Data {
      if mode.usesShellV2 { return try stream.readExactly(count, read: connection.readChunk) }
      return try DeviceClipboardProtocol.readExactly(count, read: connection.readChunk)
    }
    #expect(try helper.launch(mode, on: connection, read: read) == header)
    #expect(try read(1) == Data([42]))
    let uploadBytes = try mode.usesShellV2 ? ADBShellV2Stream.standardInput(jar) : jar
    #expect(connection.written == (upload ? uploadBytes : Data()))
    let command = try #require(connection.commands.first)
    switch mode {
    case .clock: #expect(command.hasSuffix(" clock"))
    case .audio(.playback): #expect(command.hasSuffix(" audio --playback"))
    case .audio(.microphone): #expect(command.hasSuffix(" audio --microphone"))
    case .audio(.both): #expect(command.hasSuffix(" audio --playback --microphone"))
    default: break
    }
    let digest = SHA256.hash(data: jar).map { String(format: "%02x", $0) }.joined()
    #expect(command.contains(digest + ".jar"))
    #expect(!command.contains(jar.base64EncodedString()))
  }

  @Test
  func mapsTheDeviceClockUsingTheShortestRoundTrip() throws {
    let timestamps: [UInt64] = [2_005_000, 2_202_000, 2_459_000]
    let replies = timestamps.map { timestamp in
      withUnsafeBytes(of: timestamp.bigEndian) { Data([1, 8, 0, 0, 0]) + Data($0) }
    }
    let connection = ScriptedADBConnection(reads: replies.map { .data($0) })
    let session = DeviceHelper.Session(connection: connection, stream: ADBShellV2Stream(), header: DeviceClock.magic)
    var hostMillis = [1000, 1100, 1200, 1204, 1400, 1460].makeIterator()
    let offset = try DeviceClock.measure(session) {
      CMTime(value: Int64(hostMillis.next() ?? -1), timescale: 1000)
    }
    #expect(offset == CMTime(value: 1, timescale: 1))
    let request = try ADBShellV2Stream.standardInput(Data([1]))
    #expect(connection.written == request + request + request)
  }

  @Test
  func rejectsAnUnknownDeviceClockBeforeSendingARequest() {
    let connection = ScriptedADBConnection(reads: [])
    let session = DeviceHelper.Session(connection: connection, stream: ADBShellV2Stream(), header: Data("SNT2".utf8))
    #expect(throws: ADBError.self) { try DeviceClock.measure(session) }
    #expect(connection.written.isEmpty)
  }

  @Test
  func rejectsAnAudioCommandWithoutAnySources() throws {
    let helper = try DeviceHelper(TestDeviceHelper.jar)
    let connection = ScriptedADBConnection(reads: [])
    #expect(throws: ADBError.self) {
      try helper.launch(.audio(.off), on: connection) { _ in Data() }
    }
    #expect(connection.commands.isEmpty)
  }
}
