import AppKit

struct CaptureHistoryGridSelection {
  private(set) var ids: Set<UUID> = []
  private var anchor: UUID?

  mutating func select(_ id: UUID, modifiers: NSEvent.ModifierFlags, orderedIDs: [UUID]) {
    if modifiers.contains(.shift), let anchor,
       let start = orderedIDs.firstIndex(of: anchor), let end = orderedIDs.firstIndex(of: id) {
      let range = Set(orderedIDs[min(start, end) ... max(start, end)])
      ids = modifiers.contains(.command) ? ids.union(range) : range
    } else if modifiers.contains(.command) {
      if !ids.insert(id).inserted { ids.remove(id) }
      anchor = id
    } else {
      ids = [id]
      anchor = id
    }
  }

  mutating func select(_ ids: Set<UUID>) {
    self.ids = ids
    anchor = nil
  }

  mutating func retain(_ existingIDs: Set<UUID>) {
    ids.formIntersection(existingIDs)
    if let anchor, !existingIDs.contains(anchor) { self.anchor = nil }
  }
}

struct CaptureHistoryDeletion {
  let entryIDs: Set<UUID>
  let itemID: UUID?
  let itemCount: Int
  private let name: String

  init(entries: [CaptureHistoryEntry], item: CaptureHistoryEntry.Item? = nil) {
    entryIDs = Set(entries.map(\.id))
    itemID = item?.id
    itemCount = item == nil ? entries.reduce(0) { $0 + $1.availableItems.count } : 1
    let kinds = Set(entries.filter { !$0.availableItems.isEmpty }.map(\.kind))
    if itemCount == 0 {
      name = entries.count == 1 ? "capture" : "captures"
    } else if kinds.count == 1, let kind = kinds.first {
      name = kind.title.lowercased() + (itemCount == 1 ? "" : "s")
    } else {
      name = itemCount == 1 ? "media item" : "media items"
    }
  }

  var title: String {
    itemCount == 0 ? "Delete \(entryIDs.count) \(name)?" : "Delete \(itemCount) \(name)?"
  }

  var message: String {
    "The selected \(name) will be permanently deleted. This cannot be undone."
  }
}
