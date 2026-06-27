import Foundation

public enum ADBDisplayRotation: Int, Sendable {
  case rotation0 = 0
  case rotation90 = 1
  case rotation180 = 2
  case rotation270 = 3
}

public enum ADBVirtualTouchAction: Sendable {
  case down
  case move
  case up
  case cancel
}

/// A virtual direct-touch device backed by a persistent Android `uinput` process.
public final class ADBVirtualTouchscreen: @unchecked Sendable {
  public let initialDisplayRotation: ADBDisplayRotation

  private let connection: ADBSocketConnection
  private var activeGeometry: UInputTouchscreenProtocol.Geometry?
  private var nextTrackingID = 1
  private var isClosed = false

  fileprivate init(
    connection: ADBSocketConnection,
    initialDisplayRotation: ADBDisplayRotation
  ) {
    self.connection = connection
    self.initialDisplayRotation = initialDisplayRotation
  }

  public func send(
    action: ADBVirtualTouchAction,
    x: Double,
    y: Double,
    displayWidth: Double,
    displayHeight: Double,
    rotation: ADBDisplayRotation
  ) throws {
    guard !isClosed else {
      throw ADBError.protocolFailure("virtual touchscreen is closed")
    }

    switch action {
    case .down:
      guard activeGeometry == nil else {
        throw ADBError.protocolFailure("virtual touchscreen already has an active pointer")
      }

      let geometry = try UInputTouchscreenProtocol.Geometry(
        displayWidth: displayWidth,
        displayHeight: displayHeight,
        rotation: rotation
      )
      let point = geometry.rawPoint(x: x, y: y)
      let trackingID = nextTrackingID
      nextTrackingID = trackingID == UInputTouchscreenProtocol.maximumTrackingID ? 1 : trackingID + 1
      try connection.writeLine(
        UInputTouchscreenProtocol.injectCommand(
          action: .down,
          point: point,
          trackingID: trackingID
        )
      )
      activeGeometry = geometry

    case .move:
      guard let activeGeometry else { return }
      let point = activeGeometry.rawPoint(x: x, y: y)
      try connection.writeLine(
        UInputTouchscreenProtocol.injectCommand(
          action: .move,
          point: point,
          trackingID: nil
        )
      )

    case .up, .cancel:
      guard activeGeometry != nil else { return }
      try connection.writeLine(
        UInputTouchscreenProtocol.injectCommand(
          action: action,
          point: nil,
          trackingID: nil
        )
      )
      activeGeometry = nil
    }
  }

  public func close() {
    guard !isClosed else { return }
    if activeGeometry != nil {
      try? connection.writeLine(
        UInputTouchscreenProtocol.injectCommand(
          action: .cancel,
          point: nil,
          trackingID: nil
        )
      )
    }
    activeGeometry = nil
    isClosed = true
    connection.close()
  }
}

public extension ADBClient {
  /// Starts a virtual touchscreen when the device's Android build exposes a usable `uinput` tool.
  func startVirtualTouchscreen(deviceID: String) async throws -> ADBVirtualTouchscreen {
    let identifier = UUID().uuidString
    let name = "Snap-O Live Preview \(identifier)"
    let port = "snapo:live-preview:\(identifier)"
    let registerCommand = try UInputTouchscreenProtocol.registerCommand(name: name, port: port)
    let connection = try await makeConnection()

    do {
      try connection.sendTransport(to: deviceID)
      try connection.sendShell("exec /system/bin/uinput -")
      try connection.writeLine(registerCommand)
      let rotation = try await waitForVirtualTouchscreen(deviceID: deviceID, name: name)
      return ADBVirtualTouchscreen(
        connection: connection,
        initialDisplayRotation: rotation
      )
    } catch {
      connection.close()
      throw error
    }
  }

  func displayRotation(deviceID: String) async throws -> ADBDisplayRotation {
    let output = try await runShellString(
      deviceID: deviceID,
      command: "dumpsys input | grep -m 1 'Viewport INTERNAL: displayId=0'"
    )
    guard let rotation = UInputTouchscreenProtocol.displayRotation(from: output) else {
      throw ADBError.parseFailure("Unable to determine display rotation")
    }
    return rotation
  }

  private func waitForVirtualTouchscreen(
    deviceID: String,
    name: String
  ) async throws -> ADBDisplayRotation {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))

    while true {
      try Task.checkCancellation()
      let output = try await runShellString(deviceID: deviceID, command: "dumpsys input")
      if UInputTouchscreenProtocol.isRegisteredTouchscreen(named: name, in: output),
         let rotation = UInputTouchscreenProtocol.displayRotation(from: output) {
        return rotation
      }
      guard clock.now < deadline else { break }
      try await Task.sleep(for: .milliseconds(50))
    }

    throw ADBError.requestTimedOut("Android did not register the virtual touchscreen")
  }
}

enum UInputTouchscreenProtocol {
  static let maximumAxisValue = 32767
  static let maximumTrackingID = 65535

  struct Point: Equatable {
    let x: Int
    let y: Int
  }

  struct Geometry: Equatable {
    let displayWidth: Double
    let displayHeight: Double
    let rotation: ADBDisplayRotation

    init(
      displayWidth: Double,
      displayHeight: Double,
      rotation: ADBDisplayRotation
    ) throws {
      guard displayWidth > 0, displayHeight > 0 else {
        throw ADBError.protocolFailure("virtual touchscreen requires a positive display size")
      }
      self.displayWidth = displayWidth
      self.displayHeight = displayHeight
      self.rotation = rotation
    }

    func rawPoint(x: Double, y: Double) -> Point {
      let normalizedX = Self.normalize(x, maximum: displayWidth - 1)
      let normalizedY = Self.normalize(y, maximum: displayHeight - 1)
      let raw: (x: Double, y: Double) = switch rotation {
      case .rotation0:
        (normalizedX, normalizedY)
      case .rotation90:
        (1 - normalizedY, normalizedX)
      case .rotation180:
        (1 - normalizedX, 1 - normalizedY)
      case .rotation270:
        (normalizedY, 1 - normalizedX)
      }
      return Point(
        x: Int((raw.x * Double(maximumAxisValue)).rounded()),
        y: Int((raw.y * Double(maximumAxisValue)).rounded())
      )
    }

    private static func normalize(_ value: Double, maximum: Double) -> Double {
      guard maximum > 0 else { return 0 }
      return min(max(value, 0), maximum) / maximum
    }
  }

  static func registerCommand(name: String, port: String) throws -> String {
    let encodedName = try encodeString(name)
    let encodedPort = try encodeString(port)
    // A non-zero slot range makes InputReader retain unchanged axes as Type-B multitouch state.
    return
      #"{"id":1,"command":"register","name":"# + encodedName +
      #", "vid":6353,"pid":20199,"bus":"usb","port":"# + encodedPort +
      #", "configuration":[{"type":100,"data":[1,3]},{"type":101,"data":[330,325]},"# +
      #"{"type":103,"data":[47,53,54,57]},{"type":110,"data":[1]}],"# +
      #""abs_info":[{"code":47,"info":{"value":0,"minimum":0,"maximum":9,"fuzz":0,"flat":0,"resolution":0}},"# +
      #"{"code":53,"info":{"value":0,"minimum":0,"maximum":32767,"fuzz":0,"flat":0,"resolution":0}},"# +
      #"{"code":54,"info":{"value":0,"minimum":0,"maximum":32767,"fuzz":0,"flat":0,"resolution":0}},"# +
      #"{"code":57,"info":{"value":0,"minimum":0,"maximum":65535,"fuzz":0,"flat":0,"resolution":0}}]}"#
  }

  static func injectCommand(
    action: ADBVirtualTouchAction,
    point: Point?,
    trackingID: Int?
  ) -> String {
    let events: [Int] = switch action {
    case .down:
      if let point, let trackingID {
        [
          3, 47, 0,
          3, 57, trackingID,
          3, 53, point.x,
          3, 54, point.y,
          1, 330, 1,
          1, 325, 1,
          0, 0, 0
        ]
      } else {
        []
      }
    case .move:
      if let point {
        [
          3, 47, 0,
          3, 53, point.x,
          3, 54, point.y,
          0, 0, 0
        ]
      } else {
        []
      }
    case .up, .cancel:
      [
        3, 47, 0,
        3, 57, -1,
        1, 330, 0,
        1, 325, 0,
        0, 0, 0
      ]
    }
    let values = events.map(String.init).joined(separator: ",")
    return #"{"id":1,"command":"inject","events":["# + values + "]}"
  }

  static func displayRotation(from output: String) -> ADBDisplayRotation? {
    guard let viewport = output.split(separator: "\n").first(where: {
      $0.contains("Viewport INTERNAL: displayId=0")
    }),
      let marker = viewport.range(of: "orientation=") else { return nil }
    let suffix = viewport[marker.upperBound...]
    guard let value = suffix.first?.wholeNumberValue else { return nil }
    return ADBDisplayRotation(rawValue: value)
  }

  static func isRegisteredTouchscreen(named name: String, in output: String) -> Bool {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let readerIndex = lines.firstIndex(where: { $0.hasPrefix("Input Reader State") }) else {
      return false
    }

    var foundDevice = false
    for line in lines[(readerIndex + 1)...] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("Device "), let colon = trimmed.firstIndex(of: ":") {
        if foundDevice { return false }
        let deviceName = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        foundDevice = deviceName == name
        continue
      }
      if foundDevice, trimmed.hasPrefix("Sources:") {
        if trimmed.contains("TOUCHSCREEN") { return true }
        guard let hexadecimal = trimmed.split(separator: " ").last,
              hexadecimal.hasPrefix("0x"),
              let sources = UInt32(hexadecimal.dropFirst(2), radix: 16) else { return false }
        let sourceTypeMask: UInt32 = 0x0000_FF00
        let touchscreenType: UInt32 = 0x0000_1000
        let pointerClass: UInt32 = 0x0000_0002
        return sources & sourceTypeMask == touchscreenType && sources & pointerClass == pointerClass
      }
    }
    return false
  }

  private static func encodeString(_ value: String) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let encoded = String(data: data, encoding: .utf8) else {
      throw ADBError.parseFailure("Unable to encode uinput descriptor")
    }
    return encoded
  }
}
