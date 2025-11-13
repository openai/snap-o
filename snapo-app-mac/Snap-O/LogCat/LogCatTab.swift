import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class LogCatTab: ObservableObject, Identifiable {
  let id = UUID()

  @Published var title: String {
    didSet {
      guard title != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  @Published private(set) var hasEntries = false
  @Published private(set) var lastError: String?
  @Published var isPaused = false {
    didSet {
      guard isPaused != oldValue else { return }
      let value = isPaused
      sendToProcessor { await $0.setPaused(value) }
      notifyConfigurationChange()
    }
  }

  @Published var isSoftWrapEnabled = false {
    didSet {
      guard isSoftWrapEnabled != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  @Published var isPinnedToBottom = true
  @Published var isFilterCollapsed = true {
    didSet {
      guard isFilterCollapsed != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  @Published private(set) var unreadCount: Int = 0
  @Published var filterColumns: [[LogCatFilter]] = [] {
    didSet { handleFiltersDidChange(oldValue: oldValue) }
  }

  @Published private(set) var columnNames: [Int: String] = [:] {
    didSet {
      guard columnNames != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  @Published var quickFilterText: String = "" {
    didSet {
      guard quickFilterText != oldValue else { return }
      refreshProcessorConfiguration()
      notifyConfigurationChange()
    }
  }

  @Published private(set) var renderedEntries: [LogCatRenderedEntry] = []

  private let capacity: Int
  let processor: LogCatTabProcessor
  var isActive = false
  private var filterCounter = 0
  private var filterCancellables: [UUID: AnyCancellable] = [:]
  var onConfigurationChange: (() -> Void)?
  private static let palette: [Color] = [
    Color(red: 1.00, green: 0.42, blue: 0.42),
    Color(red: 1.00, green: 0.66, blue: 0.30),
    Color(red: 1.00, green: 0.83, blue: 0.23),
    Color(red: 0.41, green: 0.86, blue: 0.49),
    Color(red: 0.22, green: 0.85, blue: 0.66),
    Color(red: 0.30, green: 0.67, blue: 0.97),
    Color(red: 0.46, green: 0.56, blue: 0.99),
    Color(red: 0.61, green: 0.36, blue: 0.90),
    Color(red: 0.94, green: 0.40, blue: 0.58),
    Color(red: 1.00, green: 0.57, blue: 0.17)
  ]

  private func notifyConfigurationChange() {
    onConfigurationChange?()
  }

  init(title: String, capacity: Int = 20000) {
    self.title = title
    self.capacity = capacity
    let initialConfiguration = LogCatTabProcessor.Configuration(filters: [], quickFilter: nil)
    processor = LogCatTabProcessor(capacity: capacity, initialConfiguration: initialConfiguration)
    sendToProcessor { processor in
      await processor.setDeliverUpdate { [weak self] update in
        guard let self else { return }
        await handleProcessorUpdate(update)
      }
      await processor.refreshConfiguration(initialConfiguration)
    }
    sendToProcessor { [isPaused] processor in
      await processor.setPaused(isPaused)
    }
  }

  func append(_ entry: LogCatEntry) {
    guard !isPaused else { return }
    sendToProcessor { await $0.enqueue(entry) }
  }

  func reset() {
    hasEntries = false
    isPinnedToBottom = true
    renderedEntries.removeAll(keepingCapacity: true)
    unreadCount = 0
    columnNames.removeAll()
    sendToProcessor { await $0.reset() }
  }

  func clearLogs() {
    hasEntries = false
    renderedEntries.removeAll(keepingCapacity: true)
    unreadCount = 0
    sendToProcessor { await $0.reset() }
  }

  func setError(_ message: String) {
    lastError = message
  }

  func clearError() {
    lastError = nil
  }

  @discardableResult
  func addFilterColumn(after columnIndex: Int? = nil) -> LogCatFilter {
    let insertionIndex = columnIndex.map { min($0 + 1, filterColumns.count) } ?? filterColumns.count
    shiftColumnNamesForInsertion(at: insertionIndex)
    let filter = makeFilter(isEnabled: true)
    filterColumns.insert([filter], at: insertionIndex)
    pruneColumnNames()
    return filter
  }

  @discardableResult
  func addFilterColumn() -> LogCatFilter {
    addFilterColumn(after: filterColumns.count - 1)
  }

  @discardableResult
  func addFilter(toColumn columnIndex: Int) -> LogCatFilter {
    let filter = makeFilter(isEnabled: true)
    guard filterColumns.indices.contains(columnIndex) else {
      filterColumns.append([filter])
      pruneColumnNames()
      return filter
    }
    filterColumns[columnIndex].append(filter)
    pruneColumnNames()
    return filter
  }

  func removeFilter(_ filter: LogCatFilter) {
    for index in filterColumns.indices {
      if let removalIndex = filterColumns[index].firstIndex(where: { $0.id == filter.id }) {
        filterColumns[index].remove(at: removalIndex)
        if filterColumns[index].isEmpty {
          filterColumns.remove(at: index)
          shiftColumnNamesForRemoval(at: index)
        }
        pruneColumnNames()
        requestFilterRefresh()
        return
      }
    }
  }

  func requestFilterRefresh() {
    refreshProcessorConfiguration()
  }

  func unpinOnScroll() {
    isPinnedToBottom = false
  }

  @discardableResult
  func applyAutomaticFilter(
    action: LogCatFilterAction,
    field: LogCatFilterField,
    matchValue: String,
    targetColumn: Int? = nil
  ) -> LogCatFilter {
    let escaped = NSRegularExpression.escapedPattern(for: matchValue)
    let pattern = "^\(escaped)$"
    let clause = LogCatFilterCondition.Clause(field: field, pattern: pattern)
    let key = LogCatFilter.AutoKey(action: action, field: field)

    if let existing = allFilters.first(where: { $0.autoKey == key }) {
      if !existing.condition.clauses
        .contains(where: { $0.field == clause.field && $0.pattern == clause.pattern && $0.isInverted == clause.isInverted }) {
        existing.condition.clauses.append(clause)
      }
      existing.isEnabled = true
      requestFilterRefresh()
      return existing
    }

    filterCounter += 1
    let defaultName: String
    let defaultColor: Color
    switch action {
    case .include:
      defaultName = "Include \(field.displayName)"
      defaultColor = .green.opacity(0.6)
    case .exclude:
      defaultName = "Exclude \(field.displayName)"
      defaultColor = .red.opacity(0.6)
    case .none:
      defaultName = "\(field.displayName) Filter"
      defaultColor = .accentColor.opacity(0.6)
    }

    let filter = LogCatFilter(
      name: defaultName,
      isEnabled: true,
      action: action,
      isHighlightEnabled: false,
      color: defaultColor,
      condition: LogCatFilterCondition(clauses: [clause]),
      autoKey: key
    )
    if let columnIndex = targetColumn, filterColumns.indices.contains(columnIndex) {
      filterColumns[columnIndex].append(filter)
    } else {
      filterColumns.append([filter])
    }
    pruneColumnNames()
    requestFilterRefresh()
    return filter
  }

  func setColumnName(_ name: String, at index: Int) {
    guard filterColumns.indices.contains(index), filterColumns[index].count > 1 else {
      columnNames.removeValue(forKey: index)
      return
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      columnNames.removeValue(forKey: index)
      return
    }
    columnNames[index] = trimmed
  }

  private func handleFiltersDidChange(oldValue: [[LogCatFilter]]) {
    updateFilterSubscriptions(previous: oldValue.flatMap(\.self))
    if !filterColumns.isEmpty, !quickFilterText.isEmpty {
      Task { @MainActor [weak self] in
        guard let self else { return }
        quickFilterText = ""
      }
    }
    pruneColumnNames()
    refreshProcessorConfiguration()
    notifyConfigurationChange()
  }

  private func updateFilterSubscriptions(previous: [LogCatFilter]) {
    let previousIDs = Set(previous.map(\.id))
    let currentIDs = Set(allFilters.map(\.id))

    for id in previousIDs.subtracting(currentIDs) {
      filterCancellables[id]?.cancel()
      filterCancellables.removeValue(forKey: id)
    }

    for filter in allFilters where filterCancellables[filter.id] == nil {
      let cancellable = filter.objectWillChange
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.refreshProcessorConfiguration()
            self?.notifyConfigurationChange()
          }
        }
      filterCancellables[filter.id] = cancellable
    }
  }

  private func refreshProcessorConfiguration() {
    let configuration = makeProcessorConfiguration()
    sendToProcessor { await $0.refreshConfiguration(configuration) }
  }

  private func makeProcessorConfiguration() -> LogCatTabProcessor.Configuration {
    let activeColumns = filterColumns
      .map { column in
        column
          .filter(\.isEnabled)
          .map(LogCatFilterSnapshot.init(filter:))
      }
      .filter { !$0.isEmpty }

    let trimmed = quickFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    let quickFilter = trimmed.isEmpty ? nil : LogCatTabProcessor.QuickFilter(pattern: NSRegularExpression.escapedPattern(for: trimmed))

    return LogCatTabProcessor.Configuration(filters: activeColumns, quickFilter: quickFilter)
  }

  private func sendToProcessor(_ work: @escaping (LogCatTabProcessor) async -> Void) {
    let processor = processor
    Task(priority: .userInitiated) {
      await work(processor)
    }
  }

  private func handleProcessorUpdate(_ update: LogCatTabProcessor.Update) async {
    switch update {
    case .tabUpdate(let tabUpdate):
      applyTabUpdate(tabUpdate)
    }
  }

  private func applyTabUpdate(_ update: LogCatTabUpdate) {
    hasEntries = update.entryCount > 0
    renderedEntries = makeRenderedEntries(from: update.renderedEntries)

    if update.didReset {
      unreadCount = 0
    } else if isActive {
      unreadCount = 0
    } else if update.metrics.unreadDelta > 0 {
      unreadCount = min(unreadCount + update.metrics.unreadDelta, 200)
    }

    if let pinnedHint = update.isPinnedToBottomHint {
      isPinnedToBottom = pinnedHint
    }

    applyErrors(from: update.errors)
  }

  private func applyErrors(from errors: [LogCatTabError]) {
    guard let first = errors.first else {
      clearError()
      return
    }

    switch first {
    case .streamWarning(let message):
      setError(message)
    case .slowProcessing(let count):
      setError("Processing may be slow \(count) messages in last batch")
    case .regexFailure(let pattern, let message):
      let detail = message ?? "Regex failure"
      setError("\(detail): \(pattern)")
    case .backlogDropped(let droppedCount):
      setError("Dropped \(droppedCount) log entries due to backlog")
    case .stateInconsistency(let message):
      setError(message)
    }
  }

  private func makeRenderedEntries(from processed: [LogCatRenderedSnapshot]) -> [LogCatRenderedEntry] {
    processed.map { item in
      let rowHighlightColor = item.rowHighlightColor?.makeNSColor()
      var fieldHighlights: [LogCatFilterField: [LogCatRenderedEntry.Highlight]] = [:]
      for (field, highlights) in item.fieldHighlights {
        let segments = highlights.map { highlight in
          LogCatRenderedEntry.Highlight(range: highlight.range.nsRange, color: highlight.color.makeNSColor())
        }
        fieldHighlights[field] = segments
      }
      return LogCatRenderedEntry(
        entry: item.entry,
        rowHighlightColor: rowHighlightColor,
        fieldHighlights: fieldHighlights
      )
    }
  }

  private var allFilters: [LogCatFilter] {
    filterColumns.flatMap(\.self)
  }

  private func makeFilter(
    name: String? = nil,
    action: LogCatFilterAction = .include,
    color: Color? = nil,
    condition: LogCatFilterCondition? = nil,
    autoKey: LogCatFilter.AutoKey? = nil,
    isEnabled: Bool = false
  ) -> LogCatFilter {
    filterCounter += 1
    let resolvedName = name ?? "Filter \(filterCounter)"
    let paletteIndex = (filterCounter - 1) % Self.palette.count
    let resolvedColor: Color = color ?? Self.palette[paletteIndex]
    let resolvedCondition = condition ?? LogCatFilterCondition()
    return LogCatFilter(
      name: resolvedName,
      isEnabled: isEnabled,
      action: action,
      color: resolvedColor,
      condition: resolvedCondition,
      autoKey: autoKey
    )
  }

  private func shiftColumnNamesForInsertion(at index: Int) {
    guard !columnNames.isEmpty else { return }
    var updated: [Int: String] = [:]
    for (key, value) in columnNames {
      updated[key >= index ? key + 1 : key] = value
    }
    columnNames = updated
  }

  private func shiftColumnNamesForRemoval(at index: Int) {
    guard !columnNames.isEmpty else { return }
    var updated: [Int: String] = [:]
    for (key, value) in columnNames {
      guard key != index else { continue }
      let newKey = key > index ? key - 1 : key
      updated[newKey] = value
    }
    columnNames = updated
  }

  private func pruneColumnNames() {
    if filterColumns.isEmpty {
      columnNames.removeAll()
      return
    }
    guard !columnNames.isEmpty else { return }
    var updated: [Int: String] = [:]
    for (index, column) in filterColumns.enumerated() where column.count > 1 {
      if let existing = columnNames[index] {
        updated[index] = existing
      }
    }
    columnNames = updated
  }

  func applyRestoredColumnNames(_ names: [Int: String]) {
    columnNames = names
  }

  func markAsRead() {
    unreadCount = 0
  }
}
