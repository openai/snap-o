import CoreMedia
import Foundation

enum DeviceClock {
  static let magic = Data("SNT1".utf8)

  /// Add this offset to a computer microphone timestamp to place it on the Android capture clock.
  static func offset(for target: DeviceTarget) async throws -> CMTime {
    let helper = try DeviceHelper(DeviceHelper.bundledBytes())
    let session = try await helper.connect(.clock, serial: target.serial, adb: ADBClient().bound(to: target))
    defer { session.connection.close() }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result {
            try session.connection.withRequestTimeout(.seconds(8)) { try measure(session) }
          })
        }
      }
    } onCancel: { session.connection.close() }
  }

  static func measure(
    _ session: DeviceHelper.Session, hostTime: () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
  ) throws -> CMTime {
    guard session.header == magic else { throw ADBError.protocolFailure("Unsupported device clock protocol") }
    let request = try ADBShellV2Stream.standardInput(Data([1]))
    var stream = session.stream
    var shortest = CMTime.positiveInfinity
    var offset = CMTime.invalid
    for _ in 0 ..< 3 {
      let sent = hostTime()
      try session.connection.writeFully(request)
      let bytes = try stream.readExactly(8, read: session.connection.readChunk)
      let roundTrip = hostTime() - sent
      let micros = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      guard micros <= Int64.max else { throw ADBError.protocolFailure("Invalid device clock timestamp") }
      // The shortest round trip gives the tightest bound on when Android sampled its clock.
      if roundTrip < shortest {
        shortest = roundTrip
        let midpoint = sent + CMTimeMultiplyByRatio(roundTrip, multiplier: 1, divisor: 2)
        offset = CMTime(value: Int64(micros), timescale: 1_000_000) - midpoint
      }
    }
    return offset
  }
}
