import Foundation
import Testing

struct CaptureHistoryNavigationTests {
  @Test
  func followsGridAndDeviceOrderInBothDirections() {
    let screenshot = item()
    let firstDevice = item()
    let secondDevice = item()
    let recording = item()
    let newest = entry(.image, items: [screenshot])
    var group = entry(.video, items: [firstDevice, item(available: false), secondDevice])
    group.capturePaneSelectionID = secondDevice.id
    let oldest = entry(.video, items: [recording])
    let entries = [newest, entry(.image, items: []), group, oldest]
    let order = [(newest, screenshot), (group, secondDevice), (group, firstDevice), (oldest, recording)]

    for (index, current) in order.enumerated() {
      let neighbors = CaptureHistoryNeighbors(entries: entries, entryID: current.0.id, itemID: current.1.id)
      let previous = order[..<index].last
      let next = order.dropFirst(index + 1).first
      #expect(neighbors.previous?.entry.id == previous?.0.id)
      #expect(neighbors.previous?.item.id == previous?.1.id)
      #expect(neighbors.next?.entry.id == next?.0.id)
      #expect(neighbors.next?.item.id == next?.1.id)
    }
  }

  @Test
  func canLeaveAnUnavailableEntryInEitherDirection() {
    let newer = entry(.image, items: [item()])
    let unavailable = entry(.video, items: [item(available: false)])
    let older = entry(.image, items: [item()])
    let neighbors = CaptureHistoryNeighbors(entries: [newer, unavailable, older], entryID: unavailable.id, itemID: nil)
    #expect(neighbors.previous?.entry.id == newer.id)
    #expect(neighbors.next?.entry.id == older.id)
  }

  @Test
  func singleCaptureAndGridHaveNoNeighbors() {
    let capture = item()
    let only = entry(.image, items: [capture])
    for id in [only.id, nil, UUID()] {
      let neighbors = CaptureHistoryNeighbors(entries: [only], entryID: id, itemID: capture.id)
      #expect(neighbors.previous == nil)
      #expect(neighbors.next == nil)
    }
  }

  private func entry(_ kind: CaptureHistoryEntry.Kind, items: [CaptureHistoryEntry.Item]) -> CaptureHistoryEntry {
    CaptureHistoryEntry(id: UUID(), kind: kind, capturedAt: .now, completedAt: .now, items: items)
  }

  private func item(available: Bool = true) -> CaptureHistoryEntry.Item {
    CaptureHistoryEntry.Item(
      id: UUID(), deviceID: UUID().uuidString, deviceName: "Test device",
      captureID: available ? UUID() : nil, failure: available ? nil : "Unavailable"
    )
  }
}
