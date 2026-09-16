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
  @State private var selectedEntryID: UUID?
  @State private var selectedItemID: UUID?
  @State private var isFocused = false
  @State private var showsSettings = false
  @State private var confirmsDeletion = false
  @State private var errorMessage: String?
  @State private var protectionID = UUID()
  @State private var timestampsUpdatedAt = Date()
  @State private var draggedMedia: CaptureHistoryDraggedMedia?
  @State private var insertion: CaptureHistoryInsertion?
  @FocusState private var hasKeyboardFocus: Bool

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
        if isFocused, let item, item.isAvailable {
          focusedPreview(entry, item: item)
        } else {
          groupOverview(entry)
        }
      }
    }
    .frame(minWidth: 460, minHeight: 380)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlayPreferenceValue(CaptureHistoryDropBounds.self) { anchors in
      GeometryReader { geometry in
        CaptureHistoryDropTarget(
          sourceID: draggedMedia?.entryID == entry?.id ? draggedMedia?.itemID : nil,
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
    .onChange(of: draggedMedia?.itemID) { insertion = nil }
    .navigationTitle("Capture History")
    .navigationSubtitle(entry.map { $0.capturedAt.formatted(date: .abbreviated, time: .shortened) } ?? "")
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
      .onChange(of: history.entries) { timestampsUpdatedAt = Date() }
      .onKeyPress(.leftArrow) { entry == nil ? .ignored : navigate(-1) }
      .onKeyPress(.rightArrow) { entry == nil ? .ignored : navigate(1) }
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
      .onChange(of: history.entries.map(\.id)) {
        if entry == nil {
          selectedEntryID = nil
          selectedItemID = nil
          isFocused = false
        }
      }
      .focusedSceneValue(\.captureHistoryActions, actions)
  }

  var body: some View {
    interactiveContent
      .sheet(isPresented: $showsSettings) { CaptureHistorySettings(history: history) }
      .alert("Delete capture?", isPresented: $confirmsDeletion) {
        Button("Delete", role: .destructive) { deleteSelection() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("All device files in this capture will be removed. Exported copies are kept.")
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
          ForEach(days, id: \.self) { day in
            Section {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 28) {
                ForEach(history.entries.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: day) }) { entry in
                  Button { open(entry) } label: {
                    CaptureHistoryStack(entry: entry, root: history.repository.root, refreshedAt: timestampsUpdatedAt)
                  }
                  .buttonStyle(.plain)
                  .id(entry.id)
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

  private var days: [Date] {
    Array(Set(history.entries.map { Calendar.current.startOfDay(for: $0.capturedAt) })).sorted(by: >)
  }

  private func dayTitle(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.month(.wide).day())
  }

  private func groupOverview(_ entry: CaptureHistoryEntry) -> some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 24)], spacing: 24) {
        ForEach(entry.orderedItems) { item in
          VStack(spacing: 10) {
            Button { focus(item, in: entry) } label: {
              CaptureHistoryThumbnail(entry: entry, item: item, root: history.repository.root)
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.isAvailable)
            .accessibilityLabel("Open \(item.deviceName)")
            .modifier(CaptureHistoryItemDrag(
              entry: entry,
              item: item,
              draggedMedia: $draggedMedia,
              dropPadding: 12,
              insertion: insertion
            ) {
              dragFile(entry, item: item)
            })
            Text(item.deviceName).font(.callout)
            if let failure = item.failure {
              Text(failure).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
          }
        }
      }
      .animation(.easeOut(duration: 0.1), value: entry.orderedItems.map(\.id))
      .padding(24)
    }
  }

  private func focusedPreview(_ entry: CaptureHistoryEntry, item: CaptureHistoryEntry.Item) -> some View {
    VStack(spacing: 12) {
      GeometryReader { geometry in
        let url = entry.fileURL(for: item, in: history.repository.root)
        Group {
          if entry.kind == .image {
            ImageCaptureView(url: url) { dragFile(entry, item: item) }
          } else {
            VideoCaptureView(url: url) { dragFile(entry, item: item) }
          }
        }
        .aspectRatio(item.aspectRatio, contentMode: .fit)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .id(item.id)
      }
      Text(item.deviceName).font(.callout).foregroundStyle(.secondary)
      if entry.items.count > 1 {
        ScrollView(.horizontal) {
          HStack(spacing: 16) {
            ForEach(entry.orderedItems) { candidate in
              Button { focus(candidate, in: entry) } label: {
                CaptureHistoryThumbnail(entry: entry, item: candidate, root: history.repository.root)
                  .frame(width: min(120, 70 * candidate.aspectRatio), height: 70)
                  .padding(4)
                  .overlay {
                    if candidate.id == item.id {
                      RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
                    }
                  }
              }
              .buttonStyle(.plain)
              .disabled(!candidate.isAvailable)
              .help(candidate.failure ?? candidate.deviceName)
              .accessibilityLabel(candidate.deviceName)
              .accessibilityAddTraits(candidate.id == item.id ? [.isSelected] : [])
              .modifier(CaptureHistoryItemDrag(entry: entry, item: candidate, draggedMedia: $draggedMedia, insertion: insertion) {
                dragFile(entry, item: candidate)
              })
            }
          }
          .animation(.easeOut(duration: 0.1), value: entry.orderedItems.map(\.id))
          .padding(4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .defaultScrollAnchor(.center)
      }
    }
    .padding(20)
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    if entry != nil {
      ToolbarItem(placement: .navigation) {
        Button(action: goBack) { Label("Back", systemImage: "chevron.left") }
          .help(isFocused && (entry?.items.count ?? 0) > 1 ? "Show all devices (Esc)" : "History (Esc)")
      }
      ToolbarItemGroup {
        Button(action: saveSelection) { Label("Save As…", systemImage: "square.and.arrow.up") }
          .disabled(item?.isAvailable != true)
          .help("Save As… (⌘S)")
        Button { confirmsDeletion = true } label: { Label("Delete Capture", systemImage: "trash") }
          .disabled(entry?.completedAt == nil)
          .help("Delete Capture")
      }
    }
    ToolbarItem {
      Button { showsSettings = true } label: { Label("History Storage", systemImage: "slider.horizontal.3") }
        .help("History Storage")
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
    selectedEntryID = entry.id
    selectedItemID = entry.frontItem?.id
    isFocused = entry.items.count == 1 && entry.frontItem != nil
    hasKeyboardFocus = true
  }

  private func focus(_ item: CaptureHistoryEntry.Item, in entry: CaptureHistoryEntry) {
    guard item.isAvailable else { return }
    guard FileManager.default.fileExists(atPath: entry.fileURL(for: item, in: history.repository.root).path) else {
      errorMessage = "The original file is unavailable."
      return
    }
    selectedItemID = item.id
    isFocused = true
    hasKeyboardFocus = true
  }

  private func navigate(_ offset: Int) -> KeyPress.Result {
    guard let entry else { return .ignored }
    let items = entry.availableItems
    guard !items.isEmpty else { return .ignored }
    let index = items.firstIndex { $0.id == selectedItemID } ?? 0
    focus(items[(index + offset + items.count) % items.count], in: entry)
    return .handled
  }

  private func goBack() {
    draggedMedia = nil
    if isFocused, (entry?.items.count ?? 0) > 1 {
      isFocused = false
    } else {
      selectedEntryID = nil
      selectedItemID = nil
      isFocused = false
    }
    hasKeyboardFocus = true
  }

  private func saveSelection() {
    guard let entry, let item, item.isAvailable else { return }
    let panel = NSSavePanel()
    let kind: MediaSaveKind = entry.kind == .image ? .image : .video
    panel.nameFieldStringValue = fileStore.makeDragDestination(capturedAt: entry.capturedAt, kind: kind).lastPathComponent
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
      let destination = try fileStore.makeUniqueDragDestination(capturedAt: entry.capturedAt, kind: kind)
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

  private func deleteSelection() {
    guard let entry else { return }
    selectedEntryID = nil
    selectedItemID = nil
    isFocused = false
    Task { await history.repository.delete([entry.id], excludingOwner: protectionID) }
  }

  private func clearError() {
    errorMessage = nil
    Task { await history.repository.clearError() }
  }
}
