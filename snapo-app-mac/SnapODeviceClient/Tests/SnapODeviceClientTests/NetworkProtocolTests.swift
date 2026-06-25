import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("Network wire protocol")
struct NetworkProtocolTests {
  @Test("decodes additive sequence metadata")
  func decodesSequence() throws {
    let data = Data(#"{"method":"Network.loadingFinished","snapoSequence":42,"params":{"requestId":"r1"}}"#.utf8)
    let message = try JSONDecoder().decode(NetworkCDPMessage.self, from: data)

    #expect(message.snapoSequence == 42)
    #expect(message.method == "Network.loadingFinished")
    #expect(message.params?["requestId"] == .string("r1"))
  }

  @Test("remains compatible when sequence metadata is absent")
  func decodesLegacyMessage() throws {
    let data = Data(#"{"method":"SnapO.replayComplete"}"#.utf8)
    let message = try JSONDecoder().decode(NetworkCDPMessage.self, from: data)

    #expect(message.snapoSequence == nil)
    #expect(message.method == SnapONetworkProtocol.Method.replayComplete)
  }

  @Test("decodes the replay watermark")
  func decodesReplayWatermark() {
    let record = NetworkRecordCodec.decode(
      #"{"method":"SnapO.replayComplete","params":{"watermark":17}}"#
    )

    #expect(record == .replayComplete(watermark: 17))
  }

  @Test("decodes the shared HTTP replay contract")
  func decodesSharedReplayFixture() throws {
    let fixtureURL = repositoryRoot
      .appendingPathComponent("contracts/network/v1/http-replay.jsonl")
    let lines = try String(contentsOf: fixtureURL, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    let records = lines.map(NetworkRecordCodec.decode)

    #expect(records.count == 5)
    #expect(records[0] == .appInfo(
      NetworkAppInfo(
        protocolVersion: 1,
        packageName: "com.example.app",
        processName: "com.example.app",
        pid: 42,
        serverStartWallMs: 1_710_000_000_000,
        serverStartMonoNs: 100_000_000_000,
        mode: "safe",
        icon: nil
      )
    ))
    #expect(records[3] == .network(
      NetworkCDPMessage(
        method: "Network.loadingFinished",
        params: [
          "requestId": .string("request-1"),
          "timestamp": .number(100.25),
          "encodedDataLength": .number(12)
        ],
        snapoSequence: 3
      )
    ))
    #expect(records[4] == .replayComplete(watermark: 3))
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
