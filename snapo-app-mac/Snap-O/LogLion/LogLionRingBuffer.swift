import Foundation

struct LogLionRingBuffer {
  private var entries: [LogLionEntry] = []
  private let capacity: Int
  private var droppedEntriesCount: Int = 0

  init(capacity: Int = 10_000) {
    self.capacity = capacity
    entries.reserveCapacity(capacity)
  }

  mutating func append(_ entry: LogLionEntry) {
    entries.append(entry)
    if entries.count > capacity {
      let overflow = entries.count - capacity
      entries.removeFirst(overflow)
      droppedEntriesCount += overflow
    }
  }

  mutating func reset() {
    entries.removeAll(keepingCapacity: true)
    droppedEntriesCount = 0
  }

  var all: [LogLionEntry] { entries }
  var isEmpty: Bool { entries.isEmpty }

  mutating func consumeDropCount() -> Int {
    let count = droppedEntriesCount
    droppedEntriesCount = 0
    return count
  }
}

extension LogLionRingBuffer: Sendable {}
