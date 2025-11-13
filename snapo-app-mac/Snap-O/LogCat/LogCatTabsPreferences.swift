import Foundation
import SwiftUI

struct LogCatTabsPreferences: Codable {
  var tabs: [LogCatTabPreferences]
  var activeTabIndex: Int?
}

extension LogCatTabsPreferences {
  @MainActor
  init(tabs: [LogCatTab], activeTabID: UUID?) {
    self.tabs = tabs.map(LogCatTabPreferences.init(tab:))
    if let activeID = activeTabID,
       let index = tabs.firstIndex(where: { $0.id == activeID }) {
      activeTabIndex = index
    } else {
      activeTabIndex = nil
    }
  }

  @MainActor
  func makeTabs() -> ([LogCatTab], Int?) {
    let restoredTabs = tabs.map { $0.makeTab() }
    let resolvedIndex: Int? = if let index = activeTabIndex,
                                 restoredTabs.indices.contains(index) {
      index
    } else {
      nil
    }
    return (restoredTabs, resolvedIndex)
  }
}

struct LogCatTabPreferences: Codable {
  var title: String
  var isPaused: Bool
  var isSoftWrapEnabled: Bool
  var isFilterCollapsed: Bool
  var quickFilterText: String
  var columnNames: [Int: String]
  var filterColumns: [[LogCatFilterPreferences]]
}

extension LogCatTabPreferences {
  @MainActor
  init(tab: LogCatTab) {
    title = tab.title
    isPaused = tab.isPaused
    isSoftWrapEnabled = tab.isSoftWrapEnabled
    isFilterCollapsed = tab.isFilterCollapsed
    quickFilterText = tab.quickFilterText
    columnNames = tab.columnNames
    filterColumns = tab.filterColumns.map { column in
      column.map(LogCatFilterPreferences.init(filter:))
    }
  }

  @MainActor
  func makeTab() -> LogCatTab {
    let tab = LogCatTab(title: title)
    tab.isPaused = isPaused
    tab.isSoftWrapEnabled = isSoftWrapEnabled
    tab.isFilterCollapsed = isFilterCollapsed
    tab.quickFilterText = quickFilterText
    tab.filterColumns = filterColumns.map { column in
      column.map { $0.makeFilter() }
    }
    tab.applyRestoredColumnNames(columnNames)
    return tab
  }
}

struct LogCatFilterPreferences: Codable {
  var name: String
  var isEnabled: Bool
  var action: LogCatFilterAction
  var isHighlightEnabled: Bool
  var color: LogCatColor
  var clauses: [LogCatFilterClausePreferences]
  var autoKey: LogCatFilterAutoKeyPreferences?
}

extension LogCatFilterPreferences {
  @MainActor
  init(filter: LogCatFilter) {
    name = filter.name
    isEnabled = filter.isEnabled
    action = filter.action
    isHighlightEnabled = filter.isHighlightEnabled
    color = LogCatColor(nsColor: filter.accentNSColor)
    clauses = filter.condition.clauses.map(LogCatFilterClausePreferences.init(clause:))
    if let autoKey = filter.autoKey {
      self.autoKey = LogCatFilterAutoKeyPreferences(autoKey: autoKey)
    } else {
      autoKey = nil
    }
  }

  @MainActor
  func makeFilter() -> LogCatFilter {
    let condition = LogCatFilterCondition(clauses: clauses.map { $0.makeClause() })
    let resolvedColor = Color(nsColor: color.makeNSColor())
    return LogCatFilter(
      name: name,
      isEnabled: isEnabled,
      action: action,
      isHighlightEnabled: isHighlightEnabled,
      color: resolvedColor,
      condition: condition,
      autoKey: autoKey?.makeAutoKey()
    )
  }
}

struct LogCatFilterClausePreferences: Codable {
  var field: LogCatFilterField
  var pattern: String
  var isInverted: Bool
  var isCaseSensitive: Bool
}

extension LogCatFilterClausePreferences {
  init(clause: LogCatFilterCondition.Clause) {
    field = clause.field
    pattern = clause.pattern
    isInverted = clause.isInverted
    isCaseSensitive = clause.isCaseSensitive
  }

  func makeClause() -> LogCatFilterCondition.Clause {
    LogCatFilterCondition.Clause(
      field: field,
      pattern: pattern,
      isInverted: isInverted,
      isCaseSensitive: isCaseSensitive
    )
  }
}

struct LogCatFilterAutoKeyPreferences: Codable {
  var action: LogCatFilterAction
  var field: LogCatFilterField
}

extension LogCatFilterAutoKeyPreferences {
  init(autoKey: LogCatFilter.AutoKey) {
    action = autoKey.action
    field = autoKey.field
  }

  func makeAutoKey() -> LogCatFilter.AutoKey {
    LogCatFilter.AutoKey(action: action, field: field)
  }
}
