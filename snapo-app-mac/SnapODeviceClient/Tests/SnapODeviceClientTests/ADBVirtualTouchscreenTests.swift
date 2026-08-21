import Darwin
import Foundation
@testable import SnapODeviceClient
import Testing

@Suite("ADB virtual touchscreen")
struct ADBVirtualTouchscreenTests {
  @Test("registers a normalized direct touchscreen")
  func registrationDescriptor() throws {
    let command = try UInputTouchscreenProtocol.registerCommand(
      name: #"Snap-O "Test""#,
      port: "snapo:test"
    )
    let data = try #require(command.data(using: .utf8))
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["name"] as? String == #"Snap-O "Test""#)
    #expect(object["port"] as? String == "snapo:test")
    let configurations = try #require(object["configuration"] as? [[String: Any]])
    #expect(configurations.count == 4)
    #expect(configurations[0]["type"] as? Int == 100)
    #expect(integers(configurations[0]["data"]) == [1, 3])
    #expect(integers(configurations[1]["data"]) == [330, 325])
    #expect(integers(configurations[2]["data"]) == [47, 53, 54, 57])
    #expect(integers(configurations[3]["data"]) == [1])

    let axes = try #require(object["abs_info"] as? [[String: Any]])
    #expect(axisRange(code: 47, in: axes) == 0 ... 9)
    #expect(axisRange(code: 53, in: axes) == 0 ... 32767)
    #expect(axisRange(code: 54, in: axes) == 0 ... 32767)
    #expect(axisRange(code: 57, in: axes) == 0 ... 65535)

    #expect(command.contains(#""type":100,"data":[1,3]"#))
    #expect(command.contains(#""type":101,"data":[330,325]"#))
  }

  @Test("only enables acknowledgments on supported Android versions")
  func synchronizationSupport() {
    #expect(!UInputTouchscreenProtocol.supportsSynchronization(sdk: "34"))
    #expect(!UInputTouchscreenProtocol.supportsSynchronization(sdk: "unknown"))
    #expect(UInputTouchscreenProtocol.supportsSynchronization(sdk: "35\n"))
    #expect(UInputTouchscreenProtocol.supportsSynchronization(sdk: "37"))
  }

  @Test("matches a fragmented acknowledgment without a newline")
  func synchronizationResponse() throws {
    let command = try JSONSerialization.jsonObject(
      with: Data(UInputTouchscreenProtocol.synchronizationCommand(sequence: 42).utf8)
    ) as? [String: Any]
    #expect(command?["command"] as? String == "sync")
    #expect(command?["syncToken"] as? String == "42")

    var chunks = [Data(#"{"reason":"syn"#.utf8), Data(#"c","id":1,"syncToken":"42"}"#.utf8)]
    var deadlines: [ContinuousClock.Instant] = []
    try UInputTouchscreenProtocol.waitForSynchronization(sequence: 42) { limit, deadline in
      deadlines.append(deadline)
      #expect(limit <= 1024)
      return chunks.removeFirst()
    }
    #expect(chunks.isEmpty)
    #expect(deadlines.count == 2 && deadlines[0] == deadlines[1])
  }

  @Test("rejects wrong tokens and bounds invalid acknowledgment data")
  func invalidSynchronizationResponse() {
    #expect(throws: (any Error).self) {
      try UInputTouchscreenProtocol.waitForSynchronization(sequence: 42) { _, _ in
        Data(#"{"reason":"sync","id":1,"syncToken":"41"}"#.utf8)
      }
    }
    var bytesRead = 0
    #expect(throws: (any Error).self) {
      try UInputTouchscreenProtocol.waitForSynchronization(sequence: 42) { limit, _ in
        let count = min(128, limit)
        bytesRead += count
        return Data(repeating: UInt8(ascii: "x"), count: count)
      }
    }
    #expect(bytesRead == 1024)
  }

  @Test("does not accept a closed or timed-out acknowledgment stream")
  func missingSynchronizationResponse() {
    #expect(throws: (any Error).self) {
      try UInputTouchscreenProtocol.waitForSynchronization(sequence: 1) { _, _ in nil }
    }
    #expect(throws: (any Error).self) {
      try UInputTouchscreenProtocol.waitForSynchronization(sequence: 1) { _, _ in
        throw ADBError.requestTimedOut("Test timeout")
      }
    }
  }

  @Test("socket acknowledgments time out and accept data when readable")
  func synchronizationSocketDeadline() throws {
    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let connection = ADBSocketConnection(connectedSocket: descriptors[0])
    defer {
      connection.close()
      Darwin.close(descriptors[1])
    }
    #expect(throws: (any Error).self) {
      try connection.readChunk(maxLength: 1024, deadline: .now.advanced(by: .milliseconds(5)))
    }
    let response = Data(#"{"reason":"sync","id":1,"syncToken":"7"}"#.utf8)
    let written = response.withUnsafeBytes {
      Darwin.write(descriptors[1], $0.baseAddress, $0.count)
    }
    #expect(written == response.count)
    try UInputTouchscreenProtocol.waitForSynchronization(sequence: 7) {
      try connection.readChunk(maxLength: $0, deadline: $1)
    }
  }

  @Test("maps logical coordinates through display rotation")
  func rotationMapping() throws {
    let maximum = UInputTouchscreenProtocol.maximumAxisValue
    let originByRotation: [(ADBDisplayRotation, UInputTouchscreenProtocol.Point)] = [
      (.rotation0, .init(x: 0, y: 0)),
      (.rotation90, .init(x: maximum, y: 0)),
      (.rotation180, .init(x: maximum, y: maximum)),
      (.rotation270, .init(x: 0, y: maximum))
    ]

    for (rotation, expected) in originByRotation {
      let geometry = try UInputTouchscreenProtocol.Geometry(
        displayWidth: 2400,
        displayHeight: 1080,
        rotation: rotation
      )
      #expect(geometry.rawPoint(x: 0, y: 0) == expected)
    }

    let geometry = try UInputTouchscreenProtocol.Geometry(
      displayWidth: 100,
      displayHeight: 200,
      rotation: .rotation0
    )
    #expect(geometry.rawPoint(x: -10, y: 500) == .init(x: 0, y: maximum))
  }

  @Test("encodes type-B down move and lift events")
  func injectionEvents() throws {
    let point = UInputTouchscreenProtocol.Point(x: 123, y: 456)
    let down = try decodeInject(
      UInputTouchscreenProtocol.injectCommand(
        action: .down,
        point: point,
        trackingID: 7
      )
    )
    #expect(down.events == [
      3, 47, 0,
      3, 57, 7,
      3, 53, 123,
      3, 54, 456,
      1, 330, 1,
      1, 325, 1,
      0, 0, 0
    ])

    let move = try decodeInject(
      UInputTouchscreenProtocol.injectCommand(
        action: .move,
        point: point,
        trackingID: nil
      )
    )
    #expect(move.events == [
      3, 47, 0,
      3, 53, 123,
      3, 54, 456,
      0, 0, 0
    ])

    let up = try decodeInject(
      UInputTouchscreenProtocol.injectCommand(
        action: .up,
        point: nil,
        trackingID: nil
      )
    )
    let cancel = try decodeInject(
      UInputTouchscreenProtocol.injectCommand(
        action: .cancel,
        point: nil,
        trackingID: nil
      )
    )
    #expect(up.events == [
      3, 47, 0,
      3, 57, -1,
      1, 330, 0,
      1, 325, 0,
      0, 0, 0
    ])
    #expect(cancel.events == up.events)
  }

  @Test("waits for InputReader touchscreen registration")
  func registrationDetection() {
    let eventHubOnly = """
    Event Hub State:
      Devices:
        27: Snap-O Test
          Classes: TOUCH | TOUCH_MT | EXTERNAL
    Input Reader State (Nums of device: 1):
      Device 12: Other Device
        Sources: TOUCHSCREEN
    """
    #expect(!UInputTouchscreenProtocol.isRegisteredTouchscreen(named: "Snap-O Test", in: eventHubOnly))

    let registered = eventHubOnly + """

      Device 27: Snap-O Test
        Generation: 2
        Sources: TOUCHSCREEN
    """
    #expect(UInputTouchscreenProtocol.isRegisteredTouchscreen(named: "Snap-O Test", in: registered))

    let android12 = registered.replacingOccurrences(of: "Sources: TOUCHSCREEN", with: "Sources: 0x00001002")
    #expect(UInputTouchscreenProtocol.isRegisteredTouchscreen(named: "Snap-O Test", in: android12))
  }

  @Test("parses the active display rotation")
  func displayRotation() {
    let viewport = """
    Viewport EXTERNAL: displayId=1, orientation=1, logicalFrame=[0, 0, 900, 600]
    Viewport INTERNAL: displayId=0, port=0, orientation=3, logicalFrame=[0, 0, 2400, 1080]
    """
    #expect(UInputTouchscreenProtocol.displayRotation(from: viewport) == .rotation270)
    #expect(UInputTouchscreenProtocol.displayRotation(
      from: "Viewport INTERNAL: displayId=0, orientation=2"
    ) == .rotation180)
    #expect(UInputTouchscreenProtocol.displayRotation(from: "orientation=unknown") == nil)
  }

  @Test("sends the final position before lifting but does not move on cancel")
  func releasePosition() throws {
    let point = UInputTouchscreenProtocol.Point(x: 321, y: 654)
    let up = try decodeInject(UInputTouchscreenProtocol.injectCommand(action: .up, point: point, trackingID: nil))
    let cancel = try decodeInject(UInputTouchscreenProtocol.injectCommand(action: .cancel, point: point, trackingID: nil))
    #expect(up.events == [
      3, 47, 0, 3, 53, 321, 3, 54, 654, 0, 0, 0,
      3, 47, 0, 3, 57, -1, 1, 330, 0, 1, 325, 0, 0, 0, 0
    ])
    #expect(cancel.events == Array(up.events.suffix(15)))
  }

  private func decodeInject(_ value: String) throws -> InjectCommand {
    try JSONDecoder().decode(InjectCommand.self, from: Data(value.utf8))
  }

  private func integers(_ value: Any?) -> [Int]? {
    (value as? [NSNumber])?.map(\.intValue)
  }

  private func axisRange(
    code: Int,
    in axes: [[String: Any]]
  ) -> ClosedRange<Int>? {
    guard let axis = axes.first(where: { $0["code"] as? Int == code }),
          let info = axis["info"] as? [String: Any],
          let minimum = info["minimum"] as? Int,
          let maximum = info["maximum"] as? Int else { return nil }
    return minimum ... maximum
  }

  private struct InjectCommand: Decodable {
    let events: [Int]
  }
}
