import Foundation

enum DevicePointerProtocol {
  static let version: UInt32 = 1

  static func frame(_ event: LivePreviewPointerEvent) throws -> Data {
    let size = event.displaySize
    guard size.width.isFinite, size.height.isFinite,
          size.width >= 1, size.height >= 1, size.width <= 65536, size.height <= 65536,
          (1 ... 10).contains(event.locations.count),
          event.source != .mouse || event.locations.count == 1 else {
      throw ADBError.protocolFailure("Invalid pointer geometry")
    }
    var data = Data()
    func number(_ value: UInt32) {
      var value = value.bigEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    number(event.source == .touchscreen ? 0 : 1)
    switch event.action {
    case .down: number(0)
    case .up: number(1)
    case .move: number(2)
    case .cancel: number(3)
    }
    number(UInt32(event.locations.count))
    number(UInt32(size.width.rounded()))
    number(UInt32(size.height.rounded()))
    for point in event.locations {
      guard point.x.isFinite, point.y.isFinite else { throw ADBError.protocolFailure("Invalid pointer position") }
      number(Float(min(max(0, point.x), size.width.rounded() - 1)).bitPattern)
      number(Float(min(max(0, point.y), size.height.rounded() - 1)).bitPattern)
    }
    return data
  }
}
