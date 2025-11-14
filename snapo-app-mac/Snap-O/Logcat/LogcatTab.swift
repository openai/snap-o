import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class LogcatTab: Identifiable {
  let id = UUID()

  var title: String {
    didSet {
      guard title != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  private(set) var hasEntries = false
  private(set) var lastError: String?
  var isPaused = false {
    didSet {
      guard isPaused != oldValue else { return }
      let value = isPaused
      sendToProcessor { await $0.setPaused(value) }
      notifyConfigurationChange()
    }
  }

  var isSoftWrapEnabled = false {
    didSet {
      guard isSoftWrapEnabled != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  var isPinnedToBottom = true
  var isFilterCollapsed = true {
    didSet {
      guard isFilterCollapsed != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  private(set) var unreadCount: Int = 0
  var filterColumns: [[LogcatFilter]] = [] {
    didSet { handleFiltersDidChange(oldValue: oldValue) }
  }

  private(set) var columnNames: [Int: String] = [:] {
    didSet {
      guard columnNames != oldValue else { return }
      notifyConfigurationChange()
    }
  }

  var quickFilterText: String = "" {
    didSet {
      guard quickFilterText != oldValue else { return }
      refreshProcessorConfiguration()
      notifyConfigurationChange()
    }
  }

  private(set) var renderedEntries: [LogcatRenderedEntry] = []

  private let capacity: Int
  let processor: LogcatTabProcessor
  var isActive = false
  private var filterCounter = 0
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
    let initialConfiguration = LogcatTabProcessor.Configuration(filters: [], quickFilter: nil)
    processor = LogcatTabProcessor(capacity: capacity, initialConfiguration: initialConfiguration)
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

  func append(_ entry: LogcatEntry) {
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
  func addFilterColumn(after columnIndex: Int? = nil) -> LogcatFilter {
    let insertionIndex = columnIndex.map { min($0 + 1, filterColumns.count) } ?? filterColumns.count
    shiftColumnNamesForInsertion(at: insertionIndex)
    let filter = makeFilter(isEnabled: true)
    filterColumns.insert([filter], at: insertionIndex)
    pruneColumnNames()
    return filter
  }

  @discardableResult
  func addFilterColumn() -> LogcatFilter {
    addFilterColumn(after: filterColumns.count - 1)
  }

  @discardableResult
  func addFilter(toColumn columnIndex: Int) -> LogcatFilter {
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

  func removeFilter(_ filter: LogcatFilter) {
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
    action: LogcatFilterAction,
    field: LogcatFilterField,
    matchValue: String,
    targetColumn: Int? = nil
  ) -> LogcatFilter {
    let escaped = NSRegularExpression.escapedPattern(for: matchValue)
    let pattern = "^\(escaped)$"
    let clause = LogcatFilterCondition.Clause(field: field, pattern: pattern)
    let key = LogcatFilter.AutoKey(action: action, field: field)

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

    let filter = LogcatFilter(
      name: defaultName,
      isEnabled: true,
      action: action,
      isHighlightEnabled: false,
      color: defaultColor,
      condition: LogcatFilterCondition(clauses: [clause]),
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

  private func handleFiltersDidChange(oldValue: [[LogcatFilter]]) {
    updateFilterObservers(previous: oldValue.flatMap(\.self))
    if !filterColumns.isEmpty, !quickFilterText.isEmpty {
      Task { @MainActor [weak self] in
        guard let self else { return }
        quickFilterText = ""
      }
    }
    pruneColumnNames()
    refreshProcessorConfiguration()
    maybeAutoNameTabForFilters(previousFiltersEmpty: oldValue.isEmpty)
    notifyConfigurationChange()
  }

  private var isUsingDefaultTitle: Bool {
    guard title.hasPrefix("All Logs") else { return false }
    let suffix = title.dropFirst("All Logs".count)
    guard !suffix.isEmpty else { return true }
    guard suffix.first == " " else { return false }
    let numberPart = suffix.dropFirst()
    return !numberPart.isEmpty && numberPart.allSatisfy(\.isNumber)
  }

  private func maybeAutoNameTabForFilters(previousFiltersEmpty: Bool) {
    guard isUsingDefaultTitle, previousFiltersEmpty, !filterColumns.isEmpty else { return }
    title = "Filtered Logs"
  }

  private func updateFilterObservers(previous: [LogcatFilter]) {
    for filter in previous {
      filter.onChange = nil
    }
    for filter in allFilters {
      filter.onChange = { [weak self] in
        guard let self else { return }
        refreshProcessorConfiguration()
        notifyConfigurationChange()
      }
    }
  }

  private func refreshProcessorConfiguration() {
    let configuration = makeProcessorConfiguration()
    sendToProcessor { await $0.refreshConfiguration(configuration) }
  }

  private func makeProcessorConfiguration() -> LogcatTabProcessor.Configuration {
    let activeColumns = filterColumns
      .map { column in
        column
          .filter(\.isEnabled)
          .map(LogcatFilterSnapshot.init(filter:))
      }
      .filter { !$0.isEmpty }

    let trimmed = quickFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    let quickFilter = trimmed.isEmpty ? nil : LogcatTabProcessor.QuickFilter(pattern: NSRegularExpression.escapedPattern(for: trimmed))

    return LogcatTabProcessor.Configuration(filters: activeColumns, quickFilter: quickFilter)
  }

  private func sendToProcessor(_ work: @escaping (LogcatTabProcessor) async -> Void) {
    let processor = processor
    Task(priority: .userInitiated) {
      await work(processor)
    }
  }

  private func handleProcessorUpdate(_ update: LogcatTabProcessor.Update) async {
    switch update {
    case .tabUpdate(let tabUpdate):
      applyTabUpdate(tabUpdate)
    }
  }

  private func applyTabUpdate(_ update: LogcatTabUpdate) {
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

  private func applyErrors(from errors: [LogcatTabError]) {
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

  private func makeRenderedEntries(from processed: [LogcatRenderedSnapshot]) -> [LogcatRenderedEntry] {
    processed.map { item in
      let rowHighlightColor = item.rowHighlightColor?.makeNSColor()
      var fieldHighlights: [LogcatFilterField: [LogcatRenderedEntry.Highlight]] = [:]
      for (field, highlights) in item.fieldHighlights {
        let segments = highlights.map { highlight in
          LogcatRenderedEntry.Highlight(range: highlight.range.nsRange, color: highlight.color.makeNSColor())
        }
        fieldHighlights[field] = segments
      }
      return LogcatRenderedEntry(
        entry: item.entry,
        rowHighlightColor: rowHighlightColor,
        fieldHighlights: fieldHighlights
      )
    }
  }

  private var allFilters: [LogcatFilter] {
    filterColumns.flatMap(\.self)
  }

  private func makeFilter(
    name: String? = nil,
    action: LogcatFilterAction = .include,
    color: Color? = nil,
    condition: LogcatFilterCondition? = nil,
    autoKey: LogcatFilter.AutoKey? = nil,
    isEnabled: Bool = false
  ) -> LogcatFilter {
    filterCounter += 1
    let resolvedName = name ?? "Filter \(filterCounter)"
    let paletteIndex = (filterCounter - 1) % Self.palette.count
    let resolvedColor: Color = color ?? Self.palette[paletteIndex]
    let resolvedCondition = condition ?? LogcatFilterCondition()
    return LogcatFilter(
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
