import Foundation

extension Data {
  func trimTrailingCarriageReturn() -> Data {
    guard let last, last == UInt8(ascii: "\r") else { return self }
    return prefix(count - 1)
  }
}
