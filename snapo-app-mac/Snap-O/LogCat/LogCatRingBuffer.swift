import Foundation

/// Fixed-size FIFO buffer that overwrites the oldest entries once capacity is reached.
/// Backed by a circular array so drops do not require O(n) copies.
struct LogCatRingBuffer {
  private var storage: [LogCatEntry?]
  private var head = 0
  private var tail = 0
  private var entryCount = 0
  private let capacity: Int
  private var droppedEntriesCount: Int = 0

  init(capacity: Int = 10000) {
    self.capacity = max(0, capacity)
    storage = Array(repeating: nil, count: self.capacity)
  }

  @discardableResult
  mutating func append(_ entry: LogCatEntry) -> LogCatEntry? {
    guard capacity > 0 else { return nil }

    var dropped: LogCatEntry?
    if entryCount == capacity {
      dropped = storage[tail]
    }

    storage[tail] = entry
    tail = (tail + 1) % capacity

    if entryCount == capacity {
      head = tail
      droppedEntriesCount += 1
    } else {
      entryCount += 1
    }

    return dropped
  }

  mutating func reset() {
    guard capacity > 0 else {
      storage.removeAll(keepingCapacity: false)
      return
    }
    storage = Array(repeating: nil, count: capacity)
    head = 0
    tail = 0
    entryCount = 0
    droppedEntriesCount = 0
  }

  var all: [LogCatEntry] {
    guard capacity > 0, entryCount > 0 else { return [] }
    var result: [LogCatEntry] = []
    result.reserveCapacity(entryCount)
    for index in 0 ..< entryCount {
      let storageIndex = (head + index) % capacity
      if let entry = storage[storageIndex] {
        result.append(entry)
      }
    }
    return result
  }

  var isEmpty: Bool { entryCount == 0 }
  var currentCount: Int { entryCount }

  mutating func consumeDropCount() -> Int {
    let value = droppedEntriesCount
    droppedEntriesCount = 0
    return value
  }
}

extension LogCatRingBuffer: Sendable {}
