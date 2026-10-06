import Foundation
@testable import Snap_O

@MainActor
final class ReadyCaptureBatch: CaptureBatch {
  let id = UUID()
  let kind: CaptureKind
  let items: [CaptureItem]
  let isComplete = true
  private let fileStore: FileStore
  private var isClosed = false

  init(_ captures: [CaptureMedia], fileStore: FileStore) {
    self.fileStore = fileStore
    kind = captures.first?.media.isVideo == true ? .recording : .screenshots
    items = captures.map { capture in
      let item = CaptureItem(device: capture.device)
      item.update(.ready(capture))
      return item
    }
  }

  func start() {}
  func close() async {
    guard !isClosed else { return }
    isClosed = true
    fileStore.discardPreviews(items.compactMap(\.media))
  }
}
