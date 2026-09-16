import Foundation

struct CaptureHistoryEntry: Codable, Identifiable, Equatable {
  enum Kind: String, Codable {
    case image, video

    var symbol: String {
      self == .image ? "camera" : "record.circle"
    }

    var title: String {
      self == .image ? "Screenshot" : "Screen recording"
    }

    var fileExtension: String {
      self == .image ? "png" : "mp4"
    }
  }

  struct Item: Codable, Identifiable, Equatable {
    let id: UUID
    let deviceID: String
    let deviceName: String
    var captureID: UUID?
    var width: Double?
    var height: Double?
    var densityScale: Double?
    var byteCount: Int64 = 0
    var failure: String?

    var isAvailable: Bool {
      captureID != nil && failure == nil
    }

    var aspectRatio: Double {
      max(0.1, (width ?? 1) / max(height ?? 1, 1))
    }
  }

  let id: UUID
  let kind: Kind
  let capturedAt: Date
  var completedAt: Date?
  var items: [Item]
  var capturePaneSelectionID: UUID?

  var byteCount: Int64 {
    items.reduce(0) { $0 + $1.byteCount }
  }

  var orderedItems: [Item] {
    guard let front = frontItem else { return items }
    return [front] + items.filter { $0.id != front.id }
  }

  var availableItems: [Item] {
    orderedItems.filter(\.isAvailable)
  }

  var hasFailures: Bool {
    items.contains { $0.failure != nil }
  }

  var frontItem: Item? {
    items.first { $0.isAvailable && $0.id == capturePaneSelectionID } ?? items.first(where: \.isAvailable)
  }

  func fileURL(for item: Item, in root: URL) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
      .appendingPathComponent("\(item.id.uuidString).\(kind.fileExtension)")
  }
}

struct CaptureHistoryRetention: Codable, Equatable {
  var days = 7
  var limitBytes: Int64 = 5_000_000_000

  static let dayChoices = [1, 7, 30]
  static let sizeChoices: [Int64] = [1_000_000_000, 5_000_000_000, 10_000_000_000]

  var isValid: Bool {
    Self.dayChoices.contains(days) && Self.sizeChoices.contains(limitBytes)
  }
}

struct CaptureHistorySnapshot {
  let entries: [CaptureHistoryEntry]
  let retention: CaptureHistoryRetention
  let errorMessage: String?
}
