import AppKit
import Observation
import OSLog
import SwiftUI

struct LogCatDetailView: View {
  @Environment(LogCatStore.self) private var store: LogCatStore

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(store.isCrashPaneActive ? "Crashes" : (store.activeTab?.title ?? "LogCat"))
  }

  @ViewBuilder private var content: some View {
    if store.isCrashPaneActive {
      LogCatCrashContentView()
    } else if let tab = store.activeTab {
      LogCatTabContentView(tab: tab)
    } else {
      LogCatPlaceholderView(
        icon: "rectangle.stack",
        title: "Pick a Tab",
        message: "Choose a tab in the sidebar or create a new one to start streaming logs."
      )
    }
  }
}

private struct LogCatCrashContentView: View {
  @Environment(LogCatStore.self) private var store: LogCatStore
  @AppStorage("LogCatCrashRepoPath")
  private var crashRepoPath: String = ""
  @State private var isEditingRepoPath = false
  @State private var repoWarning: String?

  private var selection: Binding<LogCatCrashRecord.ID?> {
    Binding(
      get: { store.selectedCrashID },
      set: { store.selectCrash(id: $0) }
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      crashList
        .frame(width: 300)
      Divider()
      crashDetail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private var crashList: some View {
    VStack(alignment: .leading, spacing: 6) {
      repoRootControl
      Divider()
      if store.crashes.isEmpty {
        LogCatPlaceholderView(
          icon: "bolt.slash",
          title: "No Crashes",
          message: "When the crash buffer emits entries they will appear here."
        )
      } else {
        List(selection: selection) {
          ForEach(store.crashes) { crash in
            LogCatCrashListRow(crash: crash)
              .tag(crash.id)
          }
        }
        .listStyle(.inset)
      }
    }
  }

  @ViewBuilder private var crashDetail: some View {
    if let crash = store.selectedCrash {
      LogCatCrashDetailPane(
        crash: crash,
        repoRoot: normalizedCrashRepoPath(crashRepoPath),
        isEditingRepoRoot: isEditingRepoPath,
        openRepoEditor: showRepoEditor
      )
    } else if store.crashes.isEmpty {
      LogCatPlaceholderView(
        icon: "bolt.slash",
        title: "No Crash Selected",
        message: "Select a crash on the left to inspect its details."
      )
    } else {
      LogCatPlaceholderView(
        icon: "bolt",
        title: "Select a Crash",
        message: "Choose a crash from the list to see its stack trace."
      )
    }
  }

  private var repoRootControl: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("RepoRoot (for deep links):")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          showRepoEditor()
        } label: {
          Text(crashRepoPath.isEmpty ? "Set path" : crashRepoPath)
            .foregroundStyle(Color.accentColor)
            .underline()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditingRepoPath) {
          RepoRootEditorPopover(
            initialPath: crashRepoPath,
            onCancel: { isEditingRepoPath = false },
            onSubmit: applyRepoRootDraft,
            onClear: clearRepoRoot
          )
          .padding(16)
          .frame(width: 360)
        }
        Spacer()
      }
      if let warning = repoWarning {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(.horizontal, 10)
  }

  private func showRepoEditor() {
    repoWarning = nil
    isEditingRepoPath = true
  }

  private func applyRepoRootDraft(_ draft: String) {
    if let warning = validateRepoPath(draft) {
      repoWarning = warning
      return
    }
    crashRepoPath = normalizedCrashRepoPath(draft)
    repoWarning = nil
    isEditingRepoPath = false
  }

  private func clearRepoRoot() {
    crashRepoPath = ""
    repoWarning = nil
    isEditingRepoPath = false
  }

  private func validateRepoPath(_ path: String) -> String? {
    let normalized = normalizedCrashRepoPath(path)
    guard !normalized.isEmpty else {
      return "Please enter a path."
    }
    if isForbiddenRoot(normalized) {
      return "That path is too broad. Point directly at a repo folder."
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir),
          isDir.boolValue else {
      return "Path does not exist or is not a directory."
    }
    guard containsRequiredMarkers(at: normalized) else {
      return "Repo root must contain BUCK, BLAZE, settings.gradle, or settings.gradle.kts."
    }
    return nil
  }

  private func containsRequiredMarkers(at path: String) -> Bool {
    let candidates = ["BUCK", "BLAZE", "settings.gradle", "settings.gradle.kts"]
    return candidates.contains { FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
  }

  private func isForbiddenRoot(_ path: String) -> Bool {
    if path == "/" || path == "/Users" { return true }
    let components = URL(fileURLWithPath: path).pathComponents
    return components.count <= 3 && components.prefix(2) == ["/", "Users"]
  }
}

private struct RepoRootEditorPopover: View {
  let initialPath: String
  let onCancel: () -> Void
  let onSubmit: (String) -> Void
  let onClear: () -> Void
  @State private var draft: String

  init(
    initialPath: String,
    onCancel: @escaping () -> Void,
    onSubmit: @escaping (String) -> Void,
    onClear: @escaping () -> Void
  ) {
    self.initialPath = initialPath
    self.onCancel = onCancel
    self.onSubmit = onSubmit
    self.onClear = onClear
    _draft = State(initialValue: initialPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Crash Repo Root")
        .font(.headline)
      TextField("/Users/me/code/app", text: $draft)
        .textFieldStyle(.roundedBorder)
        .submitLabel(.done)
        .onSubmit {
          onSubmit(draft)
        }
      HStack {
        Button("Clear", role: .destructive) {
          onClear()
        }
        Spacer()
        Button("Cancel") {
          onCancel()
        }
        Button("Done") {
          onSubmit(draft)
        }
      }
    }
    .onAppear {
      draft = initialPath
    }
  }
}

private struct LogCatCrashListRow: View {
  let crash: LogCatCrashRecord
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(crash.preferredTitle)
        .font(.headline)
        .lineLimit(1)
      if let process = crash.processName {
        Text(process)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        Text(crash.formattedTimestamp)
          .font(.subheadline)
          .fontWeight(.semibold)
        if let relative = relativeAgeDescription {
          Text("•")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var relativeAgeDescription: String? {
    guard let timestamp = crash.timestamp else { return nil }
    return Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date())
  }
}

private struct LogCatCrashDetailPane: View {
  let crash: LogCatCrashRecord
  let repoRoot: String
  let isEditingRepoRoot: Bool
  let openRepoEditor: () -> Void
  @State private var fileResolver = CrashFileResolver()
  @State private var pendingRepoRoot: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        infoBox
        VStack(alignment: .leading, spacing: 8) {
          Text("Messages")
            .font(.headline)
          crashMessages
        }
      }
      .padding(16)
      .textSelection(.enabled)
      .onAppear {
        pendingRepoRoot = repoRoot
        applyPendingRepoRootIfPossible()
      }
      .onChange(of: repoRoot) { _, newRepoRoot in
        pendingRepoRoot = newRepoRoot
        applyPendingRepoRootIfPossible()
      }
      .onChange(of: isEditingRepoRoot) { _, newValue in
        if !newValue {
          applyPendingRepoRootIfPossible()
        }
      }
    }
  }

  private var infoBox: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(crash.preferredTitle)
        .font(.title3)
        .fontWeight(.semibold)
      infoRow(label: "Process", value: crash.processName ?? "Unknown process")
      infoRow(label: "Error", value: crash.errorTitle ?? "Unknown error")
      infoRow(label: "Timestamp", value: crash.formattedTimestamp)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    )
  }

  private func infoRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading)
      Text(value)
        .font(.body)
        .foregroundStyle(.primary)
      Spacer()
    }
  }

  private var crashMessages: some View {
    LazyVStack(alignment: .leading, spacing: 2) {
      ForEach(crashLines) { line in
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(line.prefix)
            .font(.system(.body, design: .monospaced))
          if let segment = line.segment {
            fileSegmentView(segment)
          }
          if !line.suffix.isEmpty {
            Text(line.suffix)
              .font(.system(.body, design: .monospaced))
          }
          Spacer()
        }
      }
    }
    .textSelection(.enabled)
  }

  private var crashLines: [CrashLine] {
    crash.messages.map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let indent = trimmed.hasPrefix("at ") ? "\t" : ""
      let nsRange = NSRange(location: 0, length: line.utf16.count)
      if let match = LogCatCrashDetailPane.fileRegex.firstMatch(in: line, options: [], range: nsRange),
         let fileRange = Range(match.range(at: 1), in: line),
         let lineRange = Range(match.range(at: 2), in: line) {
        let prefix = indent + String(line[..<fileRange.lowerBound])
        let suffix = String(line[lineRange.upperBound...])
        let fileName = String(line[fileRange])
        let lineNumber = String(line[lineRange])
        let link = Self.makeFileLink(
          fileName: fileName,
          lineNumber: lineNumber,
          repoRoot: repoRoot,
          resolver: fileResolver
        )
        let segment = CrashFileSegment(displayText: "\(fileName):\(lineNumber)", link: link)
        return CrashLine(prefix: prefix, segment: segment, suffix: suffix)
      } else {
        return CrashLine(prefix: indent + line, segment: nil, suffix: "")
      }
    }
  }

  private static func makeFileLink(
    fileName: String,
    lineNumber: String,
    repoRoot: String,
    resolver: CrashFileResolver
  ) -> CrashFileLink {
    let shortName = URL(fileURLWithPath: fileName).lastPathComponent
    let resolvedPath = resolver.resolvedPath(for: shortName)
    return CrashFileLink(
      fileName: shortName,
      line: lineNumber,
      filePath: resolvedPath,
      repoConfigured: !repoRoot.isEmpty
    )
  }

  private func applyPendingRepoRootIfPossible() {
    guard !isEditingRepoRoot else { return }
    let target = pendingRepoRoot ?? repoRoot
    pendingRepoRoot = target
    fileResolver.updateRoot(target)
  }

  private func openInStudio(path: String, line: String) {
    let logger = Logger(subsystem: "com.openai.snap-o", category: "CrashLinkUI")
    let escapedPath = path.replacingOccurrences(of: "'", with: "'\"'\"'")
    let command = "studio --line \(line) '\(escapedPath)'"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-c", command]
    do {
      try process.run()
    } catch {
      logger.error("Failed to launch studio for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }

  @ViewBuilder
  private func fileSegmentView(_ segment: CrashFileSegment) -> some View {
    if let path = segment.link.filePath {
      Button {
        openInStudio(path: path, line: segment.link.line)
      } label: {
        Text(segment.displayText)
          .foregroundStyle(Color.accentColor)
          .underline()
          .font(.system(.body, design: .monospaced))
      }
      .buttonStyle(.plain)
    } else if !segment.link.repoConfigured {
      Button {
        openRepoEditor()
      } label: {
        Text(segment.displayText)
          .foregroundStyle(Color.accentColor)
          .underline()
          .font(.system(.body, design: .monospaced))
      }
      .buttonStyle(.plain)
    } else {
      HStack(spacing: 4) {
        Text(segment.displayText)
          .font(.system(.body, design: .monospaced))
          .foregroundStyle(.secondary)
        if fileResolver.isIndexing {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
  }

  private struct CrashLine: Identifiable {
    let id = UUID()
    let prefix: String
    let segment: CrashFileSegment?
    let suffix: String
  }

  private struct CrashFileSegment: Identifiable {
    let id = UUID()
    let displayText: String
    let link: CrashFileLink
  }

  private struct CrashFileLink: Identifiable {
    let id = UUID()
    let fileName: String
    let line: String
    let filePath: String?
    let repoConfigured: Bool
  }

  private static let fileRegex: NSRegularExpression = {
    do {
      return try NSRegularExpression(
        pattern: #"([A-Za-z0-9_\-./\\]+?\.(?:kt|java|swift|mm|m|cpp|c|h)):(\d+)"#,
        options: []
      )
    } catch {
      preconditionFailure("Failed to compile crash file regex: \(error)")
    }
  }()
}

@MainActor
@Observable
final class CrashFileResolver {
  private(set) var isIndexing = false
  private var index: [String: [String]] = [:]
  private var currentRoot: String = ""
  private var buildTask: Task<Void, Never>?
  private nonisolated static let log = Logger(subsystem: "com.openai.snap-o", category: "CrashFileResolver")

  func updateRoot(_ path: String) {
    if currentRoot == path { return }
    currentRoot = path
    index.removeAll()
    buildTask?.cancel()
    isIndexing = false

    guard !path.isEmpty else {
      Self.log.debug("Cleared crash repo root; file hyperlinks disabled.")
      return
    }

    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
          isDir.boolValue else {
      Self.log.error("Crash repo root is invalid: \(path, privacy: .public)")
      return
    }

    isIndexing = true
    Self.log.debug("Indexing crash repo at \(path, privacy: .public)")
    buildTask = Task.detached(priority: .utility) { [path] in
      let builtIndex = CrashFileResolver.buildIndex(for: path)
      await MainActor.run {
        guard self.currentRoot == path else { return }
        self.index = builtIndex
        self.isIndexing = false
        Self.log.debug("Crash repo index finished with \(self.index.count) unique file names.")
      }
    }
  }

  func resolvedPath(for fileName: String) -> String? {
    if currentRoot.isEmpty { return nil }
    if let path = index[fileName]?.first {
      Self.log.debug("Index match for \(fileName) -> \(path, privacy: .public)")
      return path
    }
    if !isIndexing {
      let rootPath = currentRoot
      Self.log.debug("No indexed match for \(fileName, privacy: .public) under \(rootPath, privacy: .public)")
    }
    return nil
  }

  func isReady(for path: String) -> Bool {
    !path.isEmpty && currentRoot == path && !index.isEmpty
  }

  private nonisolated static func buildIndex(for path: String) -> [String: [String]] {
    var result: [String: [String]] = [:]
    let rootURL = URL(fileURLWithPath: path, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      log.error("Failed to enumerate crash repo at \(path, privacy: .public)")
      return result
    }

    for case let fileURL as URL in enumerator {
      if Task.isCancelled { return [:] }
      guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true else { continue }

      switch fileURL.pathExtension.lowercased() {
      case "kt", "java", "swift", "mm", "m", "cpp", "c", "h":
        let name = fileURL.lastPathComponent
        result[name, default: []].append(fileURL.path)
      default:
        continue
      }
    }

    return result
  }
}

private func normalizedCrashRepoPath(_ path: String) -> String {
  let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return "" }
  let expanded = (trimmed as NSString).expandingTildeInPath
  return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

private struct LogCatTabContentView: View {
  @Bindable var tab: LogCatTab
  @State private var activeFilterID: LogCatFilter.ID?
  @Environment(LogCatStore.self) private var store: LogCatStore

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      filtersBar
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Button {
        tab.isPaused.toggle()
      } label: {
        Label(tab.isPaused ? "Resume" : "Pause", systemImage: tab.isPaused ? "play.fill" : "pause.fill")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help(tab.isPaused ? "Resume streaming logs into this tab" : "Pause log streaming for this tab")

      Toggle(isOn: Binding(
        get: { tab.isSoftWrapEnabled },
        set: { tab.isSoftWrapEnabled = $0 }
      )) {
        Label("Soft Wrap", systemImage: "text.alignleft")
      }
      .toggleStyle(.button)
      .controlSize(.small)
      .help("Toggle soft wrapping for the message column")

      Toggle(isOn: Binding(
        get: { tab.isPinnedToBottom },
        set: { tab.isPinnedToBottom = $0 }
      )) {
        Label("Pin to Bottom", systemImage: tab.isPinnedToBottom ? "pin.fill" : "pin")
      }
      .toggleStyle(.button)
      .controlSize(.small)
      .help("Automatically scroll to the latest log entries")

      Button {
        activeFilterID = nil
        store.removeTab(tab)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Close this tab")
      .disabled(store.tabs.count <= 1)

      Button {
        tab.clearLogs()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Clear all logs in this tab")

      Spacer()

      HStack(spacing: 8) {
        Text("\(tab.renderedEntries.count) entries")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var filtersBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        withAnimation(.easeInOut) {
          tab.isFilterCollapsed.toggle()
          activeFilterID = nil
        }
      } label: {
        HStack(spacing: 8) {
          if !tab.filterColumns.isEmpty {
            Label(
              tab.isFilterCollapsed ? "Expand" : "Collapse",
              systemImage: tab.isFilterCollapsed ? "chevron.up" : "chevron.down"
            )
            .labelStyle(.iconOnly)
            .frame(width: 20, height: 20)
          }
          Text("Filters")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(tab.isFilterCollapsed ? "Expand filters" : "Collapse filters")

      if tab.filterColumns.isEmpty {
        HStack(spacing: 12) {
          FilterAddPlaceholder(title: "Add Filter", orientation: .horizontal) {
            let newFilter = tab.addFilterColumn()
            newFilter.isEnabled = true
            tab.requestFilterRefresh()
            activeFilterID = newFilter.id
            tab.isFilterCollapsed = false
          }
          QuickFilterTile(text: Binding(
            get: { tab.quickFilterText },
            set: { tab.quickFilterText = $0 }
          ))
        }
        .frame(height: FilterLayout.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if tab.isFilterCollapsed {
        collapsedFiltersSummary
      } else {
        filtersEditView
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var filtersEditView: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      HStack(alignment: .top, spacing: 12) {
        ForEach(Array(tab.filterColumns.enumerated()), id: \.0) { columnIndex, column in
          VStack(alignment: .leading, spacing: 6) {
            if column.count > 1 {
              TextField("Stage \(columnIndex + 1)", text: Binding(
                get: { tab.columnNames[columnIndex] ?? defaultStageName(for: columnIndex, column: column) },
                set: { tab.setColumnName($0, at: columnIndex) }
              ))
              .textFieldStyle(.roundedBorder)
              .frame(height: 24)
            } else {
              Text(defaultStageName(for: columnIndex, column: column))
                .fontWeight(.semibold)
                .frame(height: 24)
            }
            ScrollView(.vertical, showsIndicators: true) {
              ForEach(Array(column.enumerated()), id: \.element.id) { rowIndex, filter in
                VStack(spacing: 4) {
                  LogCatFilterChip(
                    filter: filter,
                    isPopoverPresented: Binding(
                      get: { activeFilterID == filter.id },
                      set: { newValue in
                        activeFilterID = newValue ? filter.id : nil
                      }
                    ),
                    onToggle: { _ in
                      tab.requestFilterRefresh()
                    },
                    onDelete: {
                      tab.removeFilter(filter)
                      activeFilterID = nil
                    }
                  )
                  .frame(width: FilterLayout.cardWidth)
                  .popover(isPresented: Binding(
                    get: { activeFilterID == filter.id },
                    set: { newValue in
                      activeFilterID = newValue ? filter.id : nil
                    }
                  ), attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                      LogCatFilterEditorView(
                        filter: filter,
                        onChange: {
                          filter.autoKey = nil
                          tab.requestFilterRefresh()
                        },
                        onDelete: {
                          tab.removeFilter(filter)
                          activeFilterID = nil
                        }
                      )
                      .frame(width: 600)
                    }.frame(maxHeight: 600)
                  }

                  if rowIndex < column.count - 1 || rowIndex == 0 {
                    OrConnector()
                      .frame(width: FilterLayout.cardWidth, alignment: .center)
                  }
                }
              }

              FilterAddPlaceholder(title: "Add Filter", orientation: .vertical) {
                let newFilter = tab.addFilter(toColumn: columnIndex)
                newFilter.isEnabled = true
                tab.requestFilterRefresh()
                activeFilterID = newFilter.id
                tab.isFilterCollapsed = false
              }
            }
          }
          VStack {
            Spacer()
            AndConnector()
            Spacer()
          }
        }
        VStack {
          Spacer()
          FilterAddPlaceholder(title: "Add Filter", orientation: .horizontal) {
            let newFilter = tab.addFilterColumn()
            newFilter.isEnabled = true
            tab.requestFilterRefresh()
            activeFilterID = newFilter.id
            tab.isFilterCollapsed = false
          }
          Spacer()
        }
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: FilterLayout.maxScrollHeight, alignment: .topLeading)
  }

  private var collapsedFiltersSummary: some View {
    Button {
      withAnimation(.easeInOut) {
        tab.isFilterCollapsed.toggle()
      }
    } label: {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          if !tab.quickFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CollapsedQuickFilterCard(text: tab.quickFilterText)
          }

          ForEach(Array(tab.filterColumns.enumerated()), id: \.0) { index, column in
            Button {
              withAnimation(.easeInOut) {
                tab.isFilterCollapsed.toggle()
                if column.count == 1, let filter = column.first {
                  activeFilterID = filter.id
                }
              }
            } label: {
              if column.count == 1, let filter = column.first {
                CollapsedFilterCard(
                  title: tab.columnNames[index] ?? defaultStageName(for: index, column: column),
                  filter: filter
                ) {
                  tab.requestFilterRefresh()
                }
              } else {
                CollapsedStageCard(
                  title: tab.columnNames[index] ?? defaultStageName(for: index, column: column),
                  filters: column
                ) { _ in
                  tab.requestFilterRefresh()
                }
              }
            }
          }
          .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
      }
      .frame(minHeight: FilterLayout.collapsedHeight)
    }
    .buttonStyle(.plain)
  }

  private func defaultStageName(for index: Int, column: [LogCatFilter]) -> String {
    if column.count == 1, let filter = column.first {
      return filter.name
    }
    return "Stage \(index + 1)"
  }

  @ViewBuilder private var content: some View {
    ZStack(alignment: .top) {
      if !tab.hasEntries {
        LogCatPlaceholderView(
          icon: "waveform.path.ecg",
          title: "Waiting for logs…",
          message: "LogCat is streaming entries into \(tab.title). They will appear here shortly."
        )
      } else if tab.renderedEntries.isEmpty {
        LogCatPlaceholderView(
          icon: "line.3.horizontal.decrease.circle",
          title: "No matches",
          message: "Current filters hide all entries. Adjust or disable filters to see more logs."
        )
      } else {
        LogCatEntriesTableView(
          tab: tab,
          onScrollInteraction: {
            DispatchQueue.main.async {
              tab.unpinOnScroll()
            }
          },
          onCreateFilter: { action, field, value in
            let filter = tab.applyAutomaticFilter(action: action, field: field, matchValue: value)
            activeFilterID = filter.id
          }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if let error = tab.lastError {
        Label {
          Text(error)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .padding()
        .transition(.opacity)
      }
    }
  }
}

private struct LogCatPlaceholderView: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 44))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct LogCatFilterChip: View {
  @Bindable var filter: LogCatFilter
  @Binding var isPopoverPresented: Bool
  var onToggle: (Bool) -> Void
  var onDelete: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      // Main tap region → opens editor popover
      Button {
        isPopoverPresented = true
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(filter.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)

          Text(filterSummaryText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()) // ensures full tap area
      }
      .buttonStyle(.plain)

      // Controls only visible on hover
      if isHovering {
        Toggle("", isOn: Binding(
          get: { filter.isEnabled },
          set: { newValue in
            filter.isEnabled = newValue
            onToggle(newValue)
          }
        ))
        .toggleStyle(ColorizedSwitchToggleStyle(color: filter.color))
        .labelsHidden()

        Button {
          onDelete()
        } label: {
          Image(systemName: "trash")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Remove filter")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: FilterLayout.cardWidth, height: FilterLayout.cardHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(filter.color.opacity(0.18))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(filter.color.opacity(0.6), lineWidth: 1)
    )
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
  }
}

private extension LogCatFilterChip {
  var filterSummaryText: String {
    let base = filter.action.displayName
    return filter.isHighlightEnabled ? "\(base) • Highlight" : base
  }
}

private enum FilterLayout {
  static let cardWidth: CGFloat = 180
  static let cardHeight: CGFloat = 70
  static let collapsedHeight: CGFloat = 40
  static let maxScrollHeight: CGFloat = 200
}

private struct ColorizedSwitchToggleStyle: ToggleStyle {
  let color: Color

  func makeBody(configuration: Configuration) -> some View {
    Toggle(configuration)
      .tint(color.opacity(0.8))
  }
}

private struct FilterAddPlaceholder: View {
  enum Orientation {
    case horizontal
    case vertical
  }

  let title: String
  let orientation: Orientation
  var action: () -> Void

  var body: some View {
    Button {
      action()
    } label: {
      VStack(spacing: 6) {
        Image(systemName: "plus")
          .font(.headline)
        Text(title)
          .font(.caption2)
      }
      .frame(width: FilterLayout.cardWidth, height: orientation == .horizontal ? FilterLayout.cardHeight : FilterLayout.cardHeight * 0.65)
      .foregroundStyle(.secondary)
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct QuickFilterTile: View {
  @Binding var text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("Quick Filter")
        .font(.caption.weight(.semibold))
      Text("Filter In full message")
        .font(.caption2)
        .foregroundStyle(.secondary)
      TextField("Regex or text", text: $text)
        .textFieldStyle(.roundedBorder)
        .disableAutocorrection(true)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .frame(width: FilterLayout.cardWidth, height: FilterLayout.cardHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.1))
    )
  }
}

private struct CollapsedQuickFilterCard: View {
  let text: String

  var body: some View {
    let displayed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: 6) {
      Text("Quick Filter")
        .font(.caption.weight(.semibold))
      Text(displayed)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: FilterLayout.cardWidth, height: FilterLayout.collapsedHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.1))
    )
  }
}

private struct CollapsedFilterCard: View {
  let title: String
  let filter: LogCatFilter
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .center) {
      Spacer()
      Text(title)
        .fontWeight(.semibold)
        .lineLimit(1)
        .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
      Toggle("", isOn: Binding(
        get: { filter.isEnabled },
        set: { newValue in
          filter.isEnabled = newValue
          onToggle()
        }
      ))
      .toggleStyle(ColorizedSwitchToggleStyle(color: filter.color))
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: FilterLayout.cardWidth, height: FilterLayout.collapsedHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.1))
    )
  }
}

private struct CollapsedStageCard: View {
  let title: String
  let filters: [LogCatFilter]
  var onToggle: (LogCatFilter) -> Void

  @State private var hideWorkItem: DispatchWorkItem?
  @State private var isExpanded: Bool = false

  var body: some View {
    HStack(alignment: .center) {
      Spacer()
      Text(title)
        .fontWeight(.semibold)
        .lineLimit(1)
      Text("• \(filters.count) filters")
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: FilterLayout.cardWidth, height: FilterLayout.collapsedHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.secondary.opacity(0.1))
    )
    .onHover { hovering in
      hideWorkItem?.cancel()
      if hovering {
        let work = DispatchWorkItem {
          withAnimation {
            isExpanded = true
          }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
      } else {
        let work = DispatchWorkItem {
          withAnimation {
            isExpanded = false
          }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
      }
    }
    .popover(isPresented: $isExpanded) {
      VStack(spacing: 10) {
        ForEach(filters) { filter in
          CollapsedStageFilterRow(filter: filter) {
            onToggle(filter)
          }
        }
      }
      .padding(16)
      .onHover { hovering in
        hideWorkItem?.cancel()
        if hovering {
          isExpanded = true
        } else {
          let work = DispatchWorkItem {
            withAnimation {
              isExpanded = false
            }
          }
          hideWorkItem = work
          DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
      }
    }
  }
}

private struct CollapsedStageFilterRow: View {
  @Bindable var filter: LogCatFilter
  var onToggle: () -> Void

  var body: some View {
    Toggle(filter.name, isOn: Binding(
      get: { filter.isEnabled },
      set: { newValue in
        filter.isEnabled = newValue
        onToggle()
      }
    ))
    .toggleStyle(ColorizedSwitchToggleStyle(color: filter.color))
    .font(.caption2)
    .lineLimit(1)
  }
}

private struct OrConnector: View {
  var body: some View {
    Text("OR")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(Color.secondary.opacity(0.15))
      )
      .foregroundStyle(.secondary)
      .frame(width: 36)
  }
}

private struct AndConnector: View {
  var body: some View {
    Text("AND")
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(Color.secondary.opacity(0.15))
      )
      .foregroundStyle(.secondary)
      .frame(width: 36)
  }
}

private struct LogCatFilterEditorView: View {
  @Bindable var filter: LogCatFilter
  var onChange: () -> Void
  var onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text("Filter Settings")
          .font(.headline)
        Spacer()
        Button(role: .destructive) {
          onDelete()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .controlSize(.small)
      }
      HStack {
        TextField("Filter Name", text: $filter.name).frame(width: 200)

        Toggle("Enabled", isOn: Binding(
          get: { filter.isEnabled },
          set: { newValue in
            filter.isEnabled = newValue
            onChange()
          }
        ))
      }
      HStack {
        Picker("Filter Type", selection: Binding(
          get: { filter.action },
          set: { newValue in
            filter.action = newValue
            filter.autoKey = nil
            onChange()
          }
        )) {
          ForEach(LogCatFilterAction.allCases) { action in
            Text(action.displayName).tag(action)
          }
        }
        .pickerStyle(.segmented)
        Toggle("Highlight matches", isOn: Binding(
          get: { filter.isHighlightEnabled },
          set: { newValue in
            filter.isHighlightEnabled = newValue
            onChange()
          }
        ))
        ColorPicker("", selection: Binding(
          get: { filter.color },
          set: { newValue in
            filter.color = newValue
            onChange()
          }
        ))
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        Text("Conditions")
          .font(.subheadline.weight(.semibold))

        LogCatFilterConditionEditor(
          condition: $filter.condition,
          onChange: onChange
        )
      }

      Spacer()
    }
    .onChange(of: filter.condition, initial: false) {
      onChange()
    }
    .padding(20)
  }
}

private let logCatLevelOptions: [LogCatLevel] = [
  .verbose, .debug, .info, .warn, .error, .fatal, .assert
]

private struct LogCatFilterConditionEditor: View {
  @Binding var condition: LogCatFilterCondition
  var onChange: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(condition.clauses.enumerated()), id: \.element.id) { index, _ in
        HStack(alignment: .center, spacing: 8) {
          Menu {
            ForEach(LogCatFilterField.allCases) { field in
              Button {
                condition.clauses[index].field = field
                onChange()
              } label: {
                if field == condition.clauses[index].field {
                  Label(field.displayName, systemImage: "checkmark")
                } else {
                  Text(field.displayName)
                }
              }
            }
          } label: {
            Text(condition.clauses[index].field.displayName)
              .font(.caption.weight(.semibold))
              .frame(width: 110, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                Capsule()
                  .fill(Color.secondary.opacity(0.15))
              )
          }
          .menuStyle(.borderlessButton)

          conditionInput(for: index)

          Toggle("Invert", isOn: Binding(
            get: { condition.clauses[index].isInverted },
            set: { newValue in
              condition.clauses[index].isInverted = newValue
              onChange()
            }
          ))
          .toggleStyle(.checkbox)

          if condition.clauses.count > 1 {
            Button {
              condition.clauses.remove(at: index)
              if condition.clauses.isEmpty {
                condition.clauses = [LogCatFilterCondition.Clause(field: .message, pattern: "")]
              }
              onChange()
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
          }
        }
      }

      Button {
        condition.clauses.append(LogCatFilterCondition.Clause(field: nextSuggestedField(), pattern: ""))
        onChange()
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func conditionInput(for index: Int) -> some View {
    if condition.clauses[index].field == .level {
      LogCatLevelSelector(selection: levelSelectionBinding(for: index))
        .frame(minWidth: 260)
    } else {
      TextField(
        "Regular Expression",
        text: Binding(
          get: { condition.clauses[index].pattern },
          set: { newValue in
            condition.clauses[index].pattern = newValue
            onChange()
          }
        )
      )
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 260)
      .overlay(alignment: .trailing) {
        Button {
          condition.clauses[index].isCaseSensitive.toggle()
          onChange()
        } label: {
          Text("Cc")
            .fontWeight(.semibold)
            .foregroundStyle(condition.clauses[index].isCaseSensitive ? Color.primary : Color.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.trailing, 6)
        .help(condition.clauses[index].isCaseSensitive ? "Case-sensitive match" : "Case-insensitive match")
      }
    }
  }

  private func levelSelectionBinding(for index: Int) -> Binding<Set<LogCatLevel>> {
    Binding(
      get: { decodeLevels(from: condition.clauses[index]) },
      set: { newSelection in
        condition.clauses[index].pattern = regexPattern(for: newSelection)
        onChange()
      }
    )
  }

  private func decodeLevels(from clause: LogCatFilterCondition.Clause) -> Set<LogCatLevel> {
    guard clause.field == .level else { return [] }
    let uppercasePattern = clause.pattern.uppercased()
    guard !uppercasePattern.isEmpty else { return [] }
    return Set(logCatLevelOptions.filter { uppercasePattern.contains($0.rawValue) })
  }

  private func regexPattern(for selection: Set<LogCatLevel>) -> String {
    guard !selection.isEmpty else { return "" }
    let symbols = selection.map(\.rawValue).sorted()
    let body = symbols.joined(separator: "|")
    return "^(\(body))$"
  }

  private func nextSuggestedField() -> LogCatFilterField {
    let priorityOrder: [LogCatFilterField] = [.message, .tag, .level, .timestamp]
    let usedFields = Set(condition.clauses.map(\.field))
    return priorityOrder.first { !usedFields.contains($0) } ?? .message
  }
}

private struct LogCatLevelSelector: View {
  @Binding var selection: Set<LogCatLevel>

  var body: some View {
    LogCatLevelSegmentedControl(selection: $selection)
      .frame(height: 30)
  }
}

private struct LogCatLevelSegmentedControl: NSViewRepresentable {
  @Binding var selection: Set<LogCatLevel>

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: logCatLevelOptions.map(\.description),
      trackingMode: .selectAny,
      target: context.coordinator,
      action: #selector(Coordinator.valueChanged(_:))
    )
    control.segmentStyle = .rounded
    control.controlSize = .small
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.selection = $selection
    for (index, level) in logCatLevelOptions.enumerated() {
      control.setLabel(level.description, forSegment: index)
      control.setSelected(selection.contains(level), forSegment: index)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<Set<LogCatLevel>>

    init(selection: Binding<Set<LogCatLevel>>) {
      self.selection = selection
    }

    @objc
    func valueChanged(_ sender: NSSegmentedControl) {
      var updated: Set<LogCatLevel> = []
      for (index, level) in logCatLevelOptions.enumerated()
        where sender.isSelected(forSegment: index) {
        updated.insert(level)
      }
      selection.wrappedValue = updated
    }
  }
}
