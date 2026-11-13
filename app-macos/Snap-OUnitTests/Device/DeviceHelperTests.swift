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

  @Test(arguments: [DeviceHelper.Mode.video, .pointer, .keyboard, .clipboard], [false, true])
  func transmitsTheJarOnlyOnRequest(mode: DeviceHelper.Mode, upload: Bool) throws {
    let jar = TestDeviceHelper.jar
    let helper = try DeviceHelper(jar)
    let header = switch mode {
    case .video: Data("SNV1".utf8)
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
    let digest = SHA256.hash(data: jar).map { String(format: "%02x", $0) }.joined()
    #expect(command.contains(digest + ".jar"))
    #expect(!command.contains(jar.base64EncodedString()))
  }
}
