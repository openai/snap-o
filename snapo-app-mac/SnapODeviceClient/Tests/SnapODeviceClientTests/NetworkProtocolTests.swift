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

  @Test("rejects legacy control messages")
  func rejectsLegacyControls() {
    #expect(NetworkRecordCodec.decode(#"{"method":"SnapO.replayComplete","params":{"watermark":17}}"#) == .unknown)
    #expect(NetworkRecordCodec.decode(#"{"id":1,"result":{}}"#) == .unknown)
  }

  @Test("decodes the shared HTTP replay contract")
  func decodesSharedReplayFixture() throws {
    let fixtureURL = repositoryRoot
      .appendingPathComponent("contracts/network/v2/history.jsonl")
    let lines = try String(contentsOf: fixtureURL, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    let records = lines.map(NetworkRecordCodec.decode)

    #expect(records.count == 3)
    #expect(records[2] == .network(
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
