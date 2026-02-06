import AppKit
import Observation
import OSLog
import SwiftUI

struct LogcatCrashContentView: View {
  @Environment(LogcatStore.self)
  private var store: LogcatStore
  @AppStorage("LogcatCrashRepoPath")
  private var crashRepoPath: String = ""
  @State private var repoWarning: String?

  private var selection: Binding<LogcatCrashRecord.ID?> {
    Binding(
      get: { store.selectedCrashID },
      set: { store.selectCrash(id: $0) }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        crashList
          .frame(width: 300)
        Divider()
        crashDetail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var crashList: some View {
    VStack(alignment: .leading, spacing: 0) {
      if store.crashes.isEmpty {
        LogcatPlaceholderView(
          icon: "bolt.slash",
          title: "No Crashes",
          message: "When the crash buffer emits entries they will appear here."
        )
      } else {
        List(selection: selection) {
          ForEach(store.crashes) { crash in
            LogcatCrashListRow(crash: crash)
              .tag(crash.id)
          }
        }
        .listStyle(.inset)
      }
    }
  }

  private var crashDetail: some View {
    VStack(alignment: .trailing, spacing: 0) {
      if let crash = store.selectedCrash {
        LogcatCrashDetailPane(
          crash: crash,
          repoRoot: normalizedCrashRepoPath(crashRepoPath),
          openRepoEditor: showRepoEditor
        )
      } else if store.crashes.isEmpty {
        LogcatPlaceholderView(
          icon: "bolt.slash",
          title: "No Crash Selected",
          message: "Select a crash on the left to inspect its details."
        )
      } else {
        LogcatPlaceholderView(
          icon: "bolt",
          title: "Select a Crash",
          message: "Choose a crash from the list to see its stack trace."
        )
      }
      Divider()
      repoRootControl
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
  }

  private var repoRootControl: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("Root path for file links:")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          showRepoEditor()
        } label: {
          Text(crashRepoPath.isEmpty ? "Set path" : crashRepoPath)
            .truncationMode(.middle)
            .lineLimit(1)
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .underline()
        }
        .buttonStyle(.plain)
        if !crashRepoPath.isEmpty {
          Button(role: .destructive) {
            clearRepoRoot()
          } label: {
            Text("Clear")
              .font(.caption)
          }
          .buttonStyle(.plain)
        }
      }
      if let warning = repoWarning {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(.bottom, 2)
  }

  @MainActor
  private func showRepoEditor() {
    repoWarning = nil
    let panel = makeRepoPickerPanel()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    applyRepoRootDraft(url.path)
  }

  private func applyRepoRootDraft(_ draft: String) {
    if let warning = validateRepoPath(draft) {
      repoWarning = warning
      return
    }
    crashRepoPath = normalizedCrashRepoPath(draft)
    repoWarning = nil
  }

  private func clearRepoRoot() {
    crashRepoPath = ""
    repoWarning = nil
  }

  @MainActor
  private func makeRepoPickerPanel() -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Select"
    panel.message = "Choose the repository root used for crash links."
    if let startURL = repoPickerStartingURL() {
      panel.directoryURL = startURL
    }
    return panel
  }

  private func repoPickerStartingURL() -> URL? {
    let normalized = normalizedCrashRepoPath(crashRepoPath)
    guard !normalized.isEmpty else {
      return FileManager.default.homeDirectoryForCurrentUser
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir),
          isDir.boolValue else {
      return FileManager.default.homeDirectoryForCurrentUser
    }
    return URL(fileURLWithPath: normalized, isDirectory: true)
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

private struct LogcatCrashListRow: View {
  let crash: LogcatCrashRecord
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

private struct LogcatCrashDetailPane: View {
  let crash: LogcatCrashRecord
  let repoRoot: String
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
      .padding(.top, 10)
      .padding(.bottom, 16)
      .padding(.horizontal, 16)
      .textSelection(.enabled)
      .onAppear {
        pendingRepoRoot = repoRoot
        applyPendingRepoRootIfPossible()
      }
      .onChange(of: repoRoot) { _, newRepoRoot in
        pendingRepoRoot = newRepoRoot
        applyPendingRepoRootIfPossible()
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
      if let match = LogcatCrashDetailPane.fileRegex.firstMatch(in: line, options: [], range: nsRange),
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
