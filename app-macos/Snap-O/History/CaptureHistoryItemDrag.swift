import SwiftUI
import UniformTypeIdentifiers

struct CaptureHistoryDraggedMedia {
  let entryID: UUID
  let itemID: UUID
  let url: URL

  func provider(kind: CaptureHistoryEntry.Kind) -> NSItemProvider {
    let provider = NSItemProvider(object: url as NSURL)
    provider.suggestedName = url.lastPathComponent
    let type = kind == .image ? UTType.png : UTType.mpeg4Movie
    provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
      completion(url, false, nil)
      return nil
    }
    return provider
  }
}

struct CaptureHistoryItemDrag: ViewModifier {
  let entry: CaptureHistoryEntry
  let item: CaptureHistoryEntry.Item
  @Binding var draggedMedia: CaptureHistoryDraggedMedia?
  var dropPadding: CGFloat = 8
  let insertion: CaptureHistoryInsertion?
  let exportFile: () -> URL?

  func body(content: Content) -> some View {
    if item.isAvailable {
      content
        .onDrag {
          guard let url = exportFile() else { return NSItemProvider() }
          let media = CaptureHistoryDraggedMedia(entryID: entry.id, itemID: item.id, url: url)
          draggedMedia = media
          return media.provider(kind: entry.kind)
        }
        .dragConfiguration(DragConfiguration(
          operationsWithinApp: .init(allowMove: true),
          operationsOutsideApp: .init()
        ))
        .onDragSessionUpdated { session in
          guard case .ended = session.phase,
                draggedMedia?.entryID == entry.id, draggedMedia?.itemID == item.id else { return }
          draggedMedia = nil
        }
        .padding(.horizontal, dropPadding)
        .anchorPreference(key: CaptureHistoryDropBounds.self, value: .bounds) { [item.id: $0] }
        .overlay(alignment: insertion?.afterTarget == true ? .trailing : .leading) {
          if insertion?.itemID == item.id {
            Rectangle()
              .fill(Color.accentColor)
              .frame(width: 2)
              .padding(.vertical, 4)
              .allowsHitTesting(false)
          }
        }
        .padding(.horizontal, -dropPadding)
    } else {
      content
    }
  }
}
