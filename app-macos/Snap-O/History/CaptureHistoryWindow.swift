import AppKit
import Darwin
import SwiftUI

struct CaptureHistoryActions {
  let save: () -> Void
  let copy: (() -> Void)?
  let previous: () -> Void
  let next: () -> Void
  let canNavigate: Bool
}

private struct CaptureHistoryActionsKey: FocusedValueKey {
  typealias Value = CaptureHistoryActions
}

extension FocusedValues {
  var captureHistoryActions: CaptureHistoryActions? {
    get { self[CaptureHistoryActionsKey.self] }
    set { self[CaptureHistoryActionsKey.self] = newValue }
  }
}

struct CaptureHistoryWindow: View {
  let history: CaptureHistory
  let fileStore: FileStore
  @Environment(\.calendar)
  private var calendar
  @State private var entriesByDay: [Date: [CaptureHistoryEntry]] = [:]
  @State private var selectedEntryID: UUID?
  @State private var selectedItemID: UUID?
  @State private var showsSettings = false
  @State private var confirmsDeletion = false
  @State private var deletion: Deletion?
  @State private var errorMessage: String?
  @State private var protectionID = UUID()
  @State private var timestampsUpdatedAt = Date()
  @State private var draggedMedia: CaptureHistoryDraggedMedia?
  @State private var insertion: CaptureHistoryInsertion?
  @State private var isVideoFocused = false
  @FocusState private var hasKeyboardFocus: Bool

  private struct Deletion {
    let entryID: UUID
    let itemID: UUID?
    let kind: CaptureHistoryEntry.Kind
    let itemCount: Int

    private var name: String {
      itemCount == 0 ? "capture" : kind.title.lowercased()
    }

    var title: String {
      itemCount > 1 ? "Delete \(itemCount) \(name)s?" : "Delete \(name)?"
    }

    var message: String {
      let subject = itemCount > 1 ? "This group" : "This \(name)"
      return "\(subject) will be permanently deleted. This cannot be undone."
    }
  }

  private var entry: CaptureHistoryEntry? {
    history.entries.first { $0.id == selectedEntryID }
  }

  private var item: CaptureHistoryEntry.Item? {
    entry?.items.first { $0.id == selectedItemID } ?? entry?.frontItem
  }

  private var protectedIDs: Set<UUID> {
    Set(entry?.items.compactMap(\.captureID) ?? [])
  }

  private var content: some View {
    ZStack {
      grid
        .opacity(entry == nil ? 1 : 0)
        .allowsHitTesting(entry == nil)
        .accessibilityHidden(entry != nil)
      if let entry {
        if let item, item.isAvailable {
          capturePreview(entry, item: item)
        } else if entry.completedAt == nil {
          ProgressView("Capturing…")
        } else {
          ContentUnavailableView {
            Label("Capture unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            ForEach(entry.items) { item in
              if let failure = item.failure {
                Text("\(item.deviceName): \(failure)")
              }
            }
          }
        }
      }
    }
    .frame(minWidth: 460, minHeight: 380)
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: draggedMedia?.itemID) { insertion = nil }
    .navigationTitle(entry?.displayName ?? "Capture History")
    .toolbar(removing: .title)
    .toolbar { toolbar }
  }

  private var interactiveContent: some View {
    content
      .background {
        CaptureHistoryMouseNavigation(
          isEnabled: entry != nil && !showsSettings && !confirmsDeletion
            && errorMessage == nil && history.errorMessage == nil,
          goBack: goBack
        )
      }
      .focusable()
      .focusEffectDisabled()
      .focused($hasKeyboardFocus)
      .onAppear {
        hasKeyboardFocus = true
        timestampsUpdatedAt = Date()
      }
      .onChange(of: history.entries, initial: true) {
        groupEntries()
        timestampsUpdatedAt = Date()
      }
      .onChange(of: calendar) { groupEntries() }
      .onKeyPress(.leftArrow) { isVideoFocused ? .ignored : navigate(-1) }
      .onKeyPress(.rightArrow) { isVideoFocused ? .ignored : navigate(1) }
      .onKeyPress(.escape) {
        guard entry != nil else { return .ignored }
        goBack()
        return .handled
      }
      .task(id: protectedIDs) {
        await history.repository.protect(protectedIDs, owner: protectionID)
      }
      .onDisappear {
        Task { await history.repository.protect([], owner: protectionID) }
      }
      .onChange(of: history.entries) {
        guard selectedEntryID != nil else { return }
        guard let entry else {
          goBack()
          return
        }
        if !entry.availableItems.contains(where: { $0.id == selectedItemID }) {
          selectedItemID = entry.frontItem?.id
          isVideoFocused = false
          hasKeyboardFocus = true
        }
      }
      .focusedSceneValue(\.captureHistoryActions, actions)
  }

  var body: some View {
    interactiveContent
      .sheet(isPresented: $showsSettings) { CaptureHistorySettings(history: history) }
      .alert(deletion?.title ?? "Delete capture?", isPresented: $confirmsDeletion, presenting: deletion) { deletion in
        Button("Delete", role: .destructive) { delete(deletion) }
        Button("Cancel", role: .cancel) {}
      } message: { deletion in
        Text(deletion.message)
      }
      .alert("Capture History", isPresented: Binding(
        get: { errorMessage != nil || history.errorMessage != nil },
        set: { if !$0 { clearError() } }
      )) {
        Button("OK") { clearError() }
      } message: { Text(errorMessage ?? history.errorMessage ?? "") }
  }

  private var grid: some View {
    ScrollView {
      if history.entries.isEmpty {
        if history.isLoaded {
          ContentUnavailableView(
            "No captures yet",
            systemImage: "photo.on.rectangle",
            description: Text("Your screenshots and recordings will appear here.")
          )
          .padding(.top, 80)
        } else { ProgressView().padding(80) }
      } else {
        LazyVStack(alignment: .leading, spacing: 24) {
          ForEach(entriesByDay.keys.sorted(by: >), id: \.self) { day in
            Section {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 28) {
                ForEach(entriesByDay[day] ?? []) { entry in
                  historyStack(entry)
                }
              }
            } header: {
              Text(dayTitle(day)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
          }
        }
        .padding(24)
      }
    }
  }

  @ViewBuilder
  private func historyStack(_ entry: CaptureHistoryEntry) -> some View {
    let stack = CaptureHistoryStack(
      entry: entry,
      root: history.repository.root,
      refreshedAt: timestampsUpdatedAt,
      open: { open(entry) },
      rename: { name in
        Task { await history.repository.rename(entry.id, to: name) }
      },
      delete: { requestDeletion(entry) }
    )
    if entry.availableItems.count == 1, let item = entry.frontItem {
      stack.modifier(CaptureHistoryItemDrag(
        entry: entry, item: item, draggedMedia: $draggedMedia, dropPadding: 0, insertion: nil
      ) {
        dragFile(entry, item: item)
      })
    } else {
      stack
    }
  }

  private func groupEntries() {
    entriesByDay = Dictionary(grouping: history.entries) { calendar.startOfDay(for: $0.capturedAt) }
  }

  private func dayTitle(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.wide).day())
  }

  private func capturePreview(_ entry: CaptureHistoryEntry, item: CaptureHistoryEntry.Item) -> some View {
    VStack(spacing: 12) {
      GeometryReader { geometry in
        let url = entry.fileURL(for: item, in: history.repository.root)
        let makeTempDragFile = { dragFile(entry, item: item) }
        Group {
          if entry.kind == .image {
            ImageCaptureView(
              url: url,
              exportFilename: FileStore.exportFilename(capturedAt: entry.capturedAt, kind: .image, name: entry.name),
              onDelete: entry.completedAt == nil ? nil : { requestDeletion(entry, item: item) },
              makeTempDragFile: makeTempDragFile
            )
          } else {
            VideoCaptureView(
              url: url,
              onFocusChange: { isVideoFocused = $0 },
              onDelete: entry.completedAt == nil ? nil : { requestDeletion(entry, item: item) },
              makeTempDragFile: makeTempDragFile
            )
          }
        }
        .aspectRatio(item.aspectRatio, contentMode: .fit)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .id(item.id)
      }
      Text(item.deviceName).font(.callout).foregroundStyle(.secondary)
    }
    .padding(20)
  }

  private func deviceSelector(_ entry: CaptureHistoryEntry) -> some View {
    let thumbnailSize: CGFloat = 36
    let padding: CGFloat = 3
    let spacing: CGFloat = 8
    let width = CGFloat(entry.items.count) * (thumbnailSize + 2 * padding + spacing)
    return ScrollView(.horizontal) {
      HStack(spacing: spacing) {
        ForEach(entry.orderedItems) { candidate in
          Button { select(candidate, in: entry) } label: {
            CaptureHistoryThumbnail(
              entry: entry, item: candidate, root: history.repository.root, squareSize: thumbnailSize
            )
            .frame(width: thumbnailSize, height: thumbnailSize)
            .padding(padding)
            .contentShape(Rectangle())
            .overlay {
              if candidate.id == item?.id {
                RoundedRectangle(cornerRadius: 6)
                  .stroke(hasKeyboardFocus && !isVideoFocused ? Color.accentColor : Color.secondary, lineWidth: 2)
              }
            }
          }
          .buttonStyle(.plain)
          .disabled(!candidate.isAvailable)
          .overlay {
            CaptureHistoryThumbnailMenu(canDelete: entry.completedAt != nil) {
              requestDeletion(entry, item: candidate)
            }
          }
          .help(candidate.failure ?? candidate.deviceName)
          .accessibilityLabel(candidate.deviceName)
          .accessibilityAddTraits(candidate.id == item?.id ? [.isSelected] : [])
          .modifier(CaptureHistoryItemDrag(
            entry: entry, item: candidate, draggedMedia: $draggedMedia, dropPadding: 4, insertion: insertion
          ) {
            dragFile(entry, item: candidate)
          })
        }
      }
      .animation(.easeOut(duration: 0.1), value: entry.orderedItems.map(\.id))
      .padding(.horizontal, spacing / 2)
      .padding(.vertical, 1)
    }
    .scrollIndicators(.hidden)
    .frame(width: min(220, width), height: thumbnailSize + 2 * padding + 2)
    .defaultScrollAnchor(.center)
    .overlayPreferenceValue(CaptureHistoryDropBounds.self) { anchors in
      GeometryReader { geometry in
        CaptureHistoryDropTarget(
          sourceID: draggedMedia?.entryID == entry.id ? draggedMedia?.itemID : nil,
          targets: anchors.mapValues { geometry[$0] },
          updateHint: { if insertion != $0 { insertion = $0 } },
          performDrop: { destination in
            guard let source = draggedMedia else { return }
            draggedMedia = nil
            insertion = nil
            Task {
              await history.repository.moveItem(
                source.itemID, to: destination.itemID,
                afterTarget: destination.afterTarget, in: source.entryID
              )
            }
          }
        )
      }
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if entry != nil {
      ToolbarItem(placement: .navigation) {
        Button(action: goBack) { Label("Back", systemImage: "chevron.left") }
          .help("History (Esc)")
      }
    }
    ToolbarItem(placement: .navigation) {
      VStack(alignment: .leading, spacing: 1) {
        if let entry {
          CaptureNameButton(entry: entry) { name in
            Task { await history.repository.rename(entry.id, to: name) }
          }
          .font(.headline)
          Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text("Capture History").font(.headline)
        }
      }
    }
    .sharedBackgroundVisibility(.hidden)
    if let entry, entry.items.count > 1 {
      ToolbarItem(placement: .principal) {
        deviceSelector(entry)
      }
      .sharedBackgroundVisibility(.hidden)
    }
    ToolbarSpacer(.flexible, placement: .primaryAction)
    ToolbarItemGroup(placement: .primaryAction) {
      if let entry {
        Button(action: saveSelection) { Label("Save As…", systemImage: "square.and.arrow.up") }
          .disabled(item?.isAvailable != true)
          .help("Save As… (⌘S)")
        Button { requestDeletion(entry) } label: { Label("Delete Capture", systemImage: "trash") }
          .disabled(entry.completedAt == nil)
          .help("Delete Capture")
      } else {
        Button { showsSettings = true } label: { Label("History Storage", systemImage: "slider.horizontal.3") }
          .help("History Storage")
      }
    }
  }

  private var actions: CaptureHistoryActions? {
    guard let entry, let item, item.isAvailable else { return nil }
    let copyAction: (() -> Void)? = entry.kind == .image ? { copySelection() } : nil
    return CaptureHistoryActions(
      save: { saveSelection() },
      copy: copyAction,
      previous: { _ = navigate(-1) }, next: { _ = navigate(1) },
      canNavigate: entry.availableItems.count > 1
    )
  }

  private func open(_ entry: CaptureHistoryEntry) {
    draggedMedia = nil
    if let item = entry.frontItem {
      select(item, in: entry)
    } else {
      selectedEntryID = entry.id
      selectedItemID = nil
      hasKeyboardFocus = true
    }
  }

  private func select(_ item: CaptureHistoryEntry.Item, in entry: CaptureHistoryEntry) {
    guard item.isAvailable else { return }
    guard FileManager.default.fileExists(atPath: entry.fileURL(for: item, in: history.repository.root).path) else {
      errorMessage = "The original file is unavailable."
      return
    }
    selectedEntryID = entry.id
    selectedItemID = item.id
    isVideoFocused = false
    hasKeyboardFocus = true
  }

  private func navigate(_ offset: Int) -> KeyPress.Result {
    guard let entry else { return .ignored }
    let items = entry.availableItems
    guard !items.isEmpty else { return .ignored }
    let index = items.firstIndex { $0.id == selectedItemID } ?? 0
    select(items[(index + offset + items.count) % items.count], in: entry)
    return .handled
  }

  private func goBack() {
    draggedMedia = nil
    selectedEntryID = nil
    selectedItemID = nil
    isVideoFocused = false
    hasKeyboardFocus = true
  }

  private func saveSelection() {
    guard let entry, let item, item.isAvailable else { return }
    let panel = NSSavePanel()
    let kind: MediaSaveKind = entry.kind == .image ? .image : .video
    panel.nameFieldStringValue = FileStore.exportFilename(capturedAt: entry.capturedAt, kind: kind, name: entry.name)
    panel.directoryURL = SaveLocation.defaultDirectory(for: kind)
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      let source = entry.fileURL(for: item, in: history.repository.root)
      // Stage the export before replacement so the managed original is never modified.
      let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
      try FileManager.default.copyItem(at: source, to: staging)
      defer { try? FileManager.default.removeItem(at: staging) }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
      } else { try FileManager.default.moveItem(at: staging, to: destination) }
      SaveLocation.setLastDirectoryURL(destination.deletingLastPathComponent(), for: kind)
    } catch { errorMessage = error.localizedDescription }
  }

  private func copySelection() {
    guard let entry, let item, entry.kind == .image,
          let image = NSImage(contentsOf: entry.fileURL(for: item, in: history.repository.root)) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  private func dragFile(_ entry: CaptureHistoryEntry, item: CaptureHistoryEntry.Item) -> URL? {
    do {
      let kind: MediaSaveKind = entry.kind == .image ? .image : .video
      let destination = try fileStore.makeUniqueDragDestination(capturedAt: entry.capturedAt, kind: kind, name: entry.name)
      let source = entry.fileURL(for: item, in: history.repository.root)
      // Copy-on-write avoids copying large recordings while starting a drag.
      if clonefile(source.path, destination.path, 0) != 0 {
        try FileManager.default.copyItem(at: source, to: destination)
      }
      return destination
    } catch { errorMessage = error.localizedDescription
      return nil
    }
  }

  private func requestDeletion(_ entry: CaptureHistoryEntry, item: CaptureHistoryEntry.Item? = nil) {
    deletion = Deletion(
      entryID: entry.id, itemID: item?.id, kind: entry.kind,
      itemCount: item == nil ? entry.availableItems.count : 1
    )
    confirmsDeletion = true
  }

  private func delete(_ deletion: Deletion) {
    Task {
      if let itemID = deletion.itemID {
        await history.repository.deleteItem(itemID, in: deletion.entryID)
      } else {
        await history.repository.delete([deletion.entryID])
      }
    }
  }

  private func clearError() {
    errorMessage = nil
    Task { await history.repository.clearError() }
  }
}
