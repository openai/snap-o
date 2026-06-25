import Foundation

actor CaptureTimestampSource {
  private var lastTimestamp: Date?

  func next(basedOn proposed: Date = Date()) -> Date {
    guard let previousTimestamp = lastTimestamp else {
      lastTimestamp = proposed
      return proposed
    }

    let lastSecond = floor(previousTimestamp.timeIntervalSince1970)
    let proposedSecond = floor(proposed.timeIntervalSince1970)
    guard proposedSecond <= lastSecond else {
      lastTimestamp = proposed
      return proposed
    }

    let adjusted = Date(timeIntervalSince1970: lastSecond + 1)
    lastTimestamp = adjusted
    return adjusted
  }
}
