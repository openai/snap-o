import AppKit
@testable import Snap_O
import Testing

struct CaptureHistoryGridSelectionTests {
  @Test
  func selectionUsesCommandAndShiftAcrossTheDisplayOrder() {
    let ids = (0 ..< 6).map { _ in UUID() }
    var selection = CaptureHistoryGridSelection()
    selection.select(ids[1], modifiers: [], orderedIDs: ids)
    selection.select(ids[4], modifiers: .shift, orderedIDs: ids)
    #expect(selection.ids == Set(ids[1 ... 4]))
    selection.select(ids[2], modifiers: .shift, orderedIDs: ids)
    #expect(selection.ids == Set(ids[1 ... 2]))
    selection.select(ids[5], modifiers: .command, orderedIDs: ids)
    #expect(selection.ids == [ids[1], ids[2], ids[5]])
    selection.select(ids[4], modifiers: [.command, .shift], orderedIDs: ids)
    #expect(selection.ids == [ids[1], ids[2], ids[4], ids[5]])
    selection.select(ids[2], modifiers: .command, orderedIDs: ids)
    #expect(selection.ids == [ids[1], ids[4], ids[5]])
    selection.select(ids[0], modifiers: [], orderedIDs: ids)
    #expect(selection.ids == [ids[0]])
    selection.retain(Set(ids.dropFirst()))
    #expect(selection.ids.isEmpty)
    selection.select(ids[3], modifiers: .shift, orderedIDs: Array(ids.dropFirst()))
    #expect(selection.ids == [ids[3]])
  }

  @Test
  func deletionCountsMediaAcrossGroupsAndExcludesFailures() {
    let images = entry(kind: .image, count: 3)
    let videos = entry(kind: .video, count: 2)
    let deletion = CaptureHistoryDeletion(entries: [images, videos])
    #expect(deletion.entryIDs == [images.id, videos.id])
    #expect(deletion.itemCount == 5)
    #expect(deletion.title == "Delete 5 media items?")
    #expect(deletion.itemID == nil)
    #expect(CaptureHistoryDeletion(entries: [images]).title == "Delete 3 screenshots?")
    #expect(CaptureHistoryDeletion(entries: [videos]).title == "Delete 2 screen recordings?")
    let individual = CaptureHistoryDeletion(entries: [images], item: images.items[0])
    #expect(individual.itemCount == 1)
    #expect(individual.itemID == images.items[0].id)
    #expect(individual.title == "Delete 1 screenshot?")
    #expect(CaptureHistoryDeletion(entries: [entry(kind: .image, count: 0)]).title == "Delete 1 capture?")
  }

  private func entry(kind: CaptureHistoryEntry.Kind, count: Int) -> CaptureHistoryEntry {
    var items = (0 ..< count).map { index in
      CaptureHistoryEntry.Item(id: UUID(), deviceID: "device-\(index)", deviceName: "Test device", captureID: UUID())
    }
    items.append(CaptureHistoryEntry.Item(id: UUID(), deviceID: "failed", deviceName: "Failed device", failure: "Unavailable"))
    return CaptureHistoryEntry(id: UUID(), kind: kind, capturedAt: Date(), completedAt: Date(), items: items)
  }
}
