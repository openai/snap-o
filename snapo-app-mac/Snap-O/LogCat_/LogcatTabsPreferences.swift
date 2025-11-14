import Foundation
import SwiftUI

struct LogcatTabsPreferences: Codable {
  var tabs: [LogcatTabPreferences]
  var activeTabIndex: Int?
}

extension LogcatTabsPreferences {
  @MainActor
  init(tabs: [LogcatTab], activeTabID: UUID?) {
    self.tabs = tabs.map(LogcatTabPreferences.init(tab:))
    if let activeID = activeTabID,
       let index = tabs.firstIndex(where: { $0.id == activeID }) {
      activeTabIndex = index
    } else {
      activeTabIndex = nil
    }
  }

  @MainActor
  func makeTabs() -> ([LogcatTab], Int?) {
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

struct LogcatTabPreferences: Codable {
  var title: String
  var isPaused: Bool
  var isSoftWrapEnabled: Bool
  var isFilterCollapsed: Bool
  var quickFilterText: String
  var columnNames: [Int: String]
  var filterColumns: [[LogcatFilterPreferences]]
}

extension LogcatTabPreferences {
  @MainActor
  init(tab: LogcatTab) {
    title = tab.title
    isPaused = tab.isPaused
    isSoftWrapEnabled = tab.isSoftWrapEnabled
    isFilterCollapsed = tab.isFilterCollapsed
    quickFilterText = tab.quickFilterText
    columnNames = tab.columnNames
    filterColumns = tab.filterColumns.map { column in
      column.map(LogcatFilterPreferences.init(filter:))
    }
  }

  @MainActor
  func makeTab() -> LogcatTab {
    let tab = LogcatTab(title: title)
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

struct LogcatFilterPreferences: Codable {
  var name: String
  var isEnabled: Bool
  var action: LogcatFilterAction
  var isHighlightEnabled: Bool
  var color: LogcatColor
  var clauses: [LogcatFilterClausePreferences]
  var autoKey: LogcatFilterAutoKeyPreferences?
}

extension LogcatFilterPreferences {
  @MainActor
  init(filter: LogcatFilter) {
    name = filter.name
    isEnabled = filter.isEnabled
    action = filter.action
    isHighlightEnabled = filter.isHighlightEnabled
    color = LogcatColor(nsColor: filter.accentNSColor)
    clauses = filter.condition.clauses.map(LogcatFilterClausePreferences.init(clause:))
    if let autoKey = filter.autoKey {
      self.autoKey = LogcatFilterAutoKeyPreferences(autoKey: autoKey)
    } else {
      autoKey = nil
    }
  }

  @MainActor
  func makeFilter() -> LogcatFilter {
    let condition = LogcatFilterCondition(clauses: clauses.map { $0.makeClause() })
    let resolvedColor = Color(nsColor: color.makeNSColor())
    return LogcatFilter(
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

struct LogcatFilterClausePreferences: Codable {
  var field: LogcatFilterField
  var pattern: String
  var isInverted: Bool
  var isCaseSensitive: Bool
}

extension LogcatFilterClausePreferences {
  init(clause: LogcatFilterCondition.Clause) {
    field = clause.field
    pattern = clause.pattern
    isInverted = clause.isInverted
    isCaseSensitive = clause.isCaseSensitive
  }

  func makeClause() -> LogcatFilterCondition.Clause {
    LogcatFilterCondition.Clause(
      field: field,
      pattern: pattern,
      isInverted: isInverted,
      isCaseSensitive: isCaseSensitive
    )
  }
}

struct LogcatFilterAutoKeyPreferences: Codable {
  var action: LogcatFilterAction
  var field: LogcatFilterField
}

extension LogcatFilterAutoKeyPreferences {
  init(autoKey: LogcatFilter.AutoKey) {
    action = autoKey.action
    field = autoKey.field
  }

  func makeAutoKey() -> LogcatFilter.AutoKey {
    LogcatFilter.AutoKey(action: action, field: field)
  }
}
