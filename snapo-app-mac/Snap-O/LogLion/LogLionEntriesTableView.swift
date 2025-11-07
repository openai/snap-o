import AppKit
import SwiftUI

@MainActor
struct LogLionEntriesTableView: NSViewRepresentable {
  let tab: LogLionTab
  var onScrollInteraction: () -> Void
  var onCreateFilter: (LogLionFilterAction, LogLionFilterField, String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false

    let tableView = LogLionTableView()
    tableView.headerView = NSTableHeaderView()
    tableView.gridStyleMask = []
    tableView.selectionHighlightStyle = .none
    tableView.usesAutomaticRowHeights = false
    tableView.rowHeight = Column.defaultRowHeight
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.backgroundColor = .clear
    tableView.usesAlternatingRowBackgroundColors = true

    context.coordinator.onCreateFilter = onCreateFilter
    context.coordinator.configure(tableView: tableView, scrollView: scrollView)

    scrollView.documentView = tableView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.onCreateFilter = onCreateFilter
    context.coordinator.update(
      tableView: context.coordinator.tableView,
      renderedEntries: tab.renderedEntries,
      softWrap: tab.isSoftWrapEnabled,
      pinnedToBottom: tab.isPinnedToBottom,
      onScrollInteraction: onScrollInteraction
    )
  }
}

// MARK: - Coordinator

  extension LogLionEntriesTableView {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
      fileprivate weak var tableView: LogLionTableView?
      private weak var scrollView: NSScrollView?
      private var renderedEntries: [LogLionRenderedEntry] = []
      private var lastEntryID: UUID?
      private var isSoftWrapEnabled = false
      private var isPinnedToBottom = true
      private var isProgrammaticScroll = false
      private var onScrollInteraction: (() -> Void)?
      private var hiddenColumns: Set<Column> = []
      var onCreateFilter: ((LogLionFilterAction, LogLionFilterField, String) -> Void)?

      fileprivate func configure(tableView: LogLionTableView, scrollView: NSScrollView) {
        self.tableView = tableView
        self.scrollView = scrollView

        tableView.delegate = self
        tableView.dataSource = self
        tableView.menuProvider = { [weak self] row, column in
          guard let self else { return nil }
          return self.contextMenu(forRow: row, columnIndex: column)
        }

        let headerView = LogLionTableHeaderView()
        headerView.menuProvider = { [weak self] columnIndex in
          guard let self else { return nil }
          return self.columnVisibilityMenu(for: columnIndex)
        }
        tableView.headerView = headerView

        applyColumnVisibility()

      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(clipViewDidChangeBounds(_:)),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(columnDidResize(_:)),
        name: NSTableView.columnDidResizeNotification,
        object: tableView
      )
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func update(
      tableView: NSTableView?,
      renderedEntries: [LogLionRenderedEntry],
      softWrap: Bool,
      pinnedToBottom: Bool,
      onScrollInteraction: @escaping () -> Void
    ) {
      guard let tableView else { return }

      let hasSoftWrapChanged = isSoftWrapEnabled != softWrap
      let lastCount = self.renderedEntries.count
      let lastIdentifier = lastEntryID
      let previousEntries = self.renderedEntries

      self.renderedEntries = renderedEntries
      self.isSoftWrapEnabled = softWrap
      self.isPinnedToBottom = pinnedToBottom
      self.onScrollInteraction = onScrollInteraction
      lastEntryID = renderedEntries.last?.id

      let updateResult = applyIncrementalUpdate(
        from: previousEntries,
        to: renderedEntries,
        tableView: tableView
      )

      if !updateResult.didUpdate {
        tableView.reloadData()
      }

      if hasSoftWrapChanged {
        if !renderedEntries.isEmpty {
          tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<renderedEntries.count))
        }
      } else if softWrap, renderedEntries.count > lastCount {
        let newIndexes = IndexSet(lastCount..<renderedEntries.count)
        tableView.noteHeightOfRows(withIndexesChanged: newIndexes)
      } else if softWrap, let range = updateResult.insertedRange, !range.isEmpty {
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: range))
      }

      let didAddEntries = renderedEntries.count > lastCount
        || (renderedEntries.count == lastCount && lastIdentifier != lastEntryID)
      if pinnedToBottom && (didAddEntries || !isViewAtBottom()) {
        scrollToBottom()
      }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      renderedEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard row >= 0, row < renderedEntries.count,
            let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue) else {
        return nil
      }

      let identifier = column.cellIdentifier
      let cellView: NSTableCellView

      if let reusable = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
        cellView = reusable
      } else {
        cellView = makeCellView(for: column, identifier: identifier)
      }

      configure(cellView, for: column, row: row)
      return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard isSoftWrapEnabled,
            row >= 0,
            row < renderedEntries.count,
            let messageColumn = Column.message.tableColumn(in: tableView) else {
        return Column.defaultRowHeight
      }

      let horizontalPadding = Column.message.horizontalPadding
      let availableWidth = max(messageColumn.width - horizontalPadding, 40)
      let message = renderedEntries[row].entry.message as NSString
      let boundingSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
      let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
      let font = Column.message.font
      let attributes: [NSAttributedString.Key: Any] = [.font: font]
      let height = message.boundingRect(with: boundingSize, options: options, attributes: attributes).height
      return max(Column.defaultRowHeight, ceil(height) + Column.message.verticalPadding)
    }

    private func applyIncrementalUpdate(from oldEntries: [LogLionRenderedEntry],
                                        to newEntries: [LogLionRenderedEntry],
                                        tableView: NSTableView) -> (didUpdate: Bool, insertedRange: Range<Int>?) {
      let oldCount = oldEntries.count
      let newCount = newEntries.count

      if oldCount == 0 || newCount == 0 {
        return (false, nil)
      }

      let maxShift = min(oldCount, newCount)
      var dropCount: Int?

      for candidate in 0...maxShift {
        let oldSlice = oldEntries.dropFirst(candidate)
        let expectedCount = oldCount - candidate
        guard expectedCount <= newCount else { continue }
        if oldSlice.elementsEqual(newEntries.prefix(expectedCount)) {
          dropCount = candidate
          break
        }
      }

      guard let drop = dropCount else { return (false, nil) }

      if drop > 0 {
        let removalIndexes = IndexSet(integersIn: 0..<drop)
        tableView.removeRows(at: removalIndexes, withAnimation: [])
      }

      let remainingOld = oldCount - drop
      let appended = max(0, newCount - remainingOld)
      var insertedRange: Range<Int>? = nil
      if appended > 0 {
        let insertionRange = (newCount - appended)..<newCount
        tableView.insertRows(at: IndexSet(integersIn: insertionRange), withAnimation: [])
        insertedRange = insertionRange
      }

      return (true, insertedRange)
    }

    private func makeCellView(for column: Column, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
      let cell = NSTableCellView()
      cell.identifier = identifier

      let textField = NSTextField(labelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.alignment = column.alignment
      textField.font = column.font
      textField.textColor = column.defaultTextColor
      textField.lineBreakMode = column.lineBreakMode(softWrap: isSoftWrapEnabled)
      textField.maximumNumberOfLines = column.maximumNumberOfLines(softWrap: isSoftWrapEnabled)
      textField.usesSingleLineMode = column.usesSingleLineMode(softWrap: isSoftWrapEnabled)
      textField.isSelectable = true
      textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      textField.setContentHuggingPriority(.defaultLow, for: .horizontal)

      cell.textField = textField
      cell.addSubview(textField)

      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: column.leadingPadding),
        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -column.trailingPadding),
        textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: Column.verticalInset),
        textField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -Column.verticalInset)
      ])

      return cell
    }

    private func configure(_ cell: NSTableCellView, for column: Column, row: Int) {
      guard let textField = cell.textField,
            row >= 0,
            row < renderedEntries.count else { return }

      let renderedEntry = renderedEntries[row]
      let entry = renderedEntry.entry

      textField.font = column.font
      textField.alignment = column.alignment
      textField.lineBreakMode = column.lineBreakMode(softWrap: isSoftWrapEnabled)
      textField.maximumNumberOfLines = column.maximumNumberOfLines(softWrap: isSoftWrapEnabled)
      textField.usesSingleLineMode = column.usesSingleLineMode(softWrap: isSoftWrapEnabled)

      let highlights = renderedEntry.highlights(for: column.filterField)
      let baseText = column.text(for: entry)
      let (displayText, effectiveHighlights) = collapsedDisplayValue(
        for: column,
        row: row,
        baseText: baseText,
        highlights: highlights
      )
      textField.attributedStringValue = makeAttributedString(
        for: column,
        entry: entry,
        text: displayText,
        highlights: effectiveHighlights
      )
    }

    private func makeAttributedString(for column: Column,
                                      entry: LogLionEntry,
                                      text: String,
                                      highlights: [LogLionRenderedEntry.Highlight]) -> NSAttributedString {
      let baseColor = column.textColor(for: entry)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: column.font,
        .foregroundColor: baseColor
      ]
      let attributed = NSMutableAttributedString(string: text, attributes: attributes)

      for highlight in highlights {
        guard highlight.range.location != NSNotFound,
              NSMaxRange(highlight.range) <= attributed.length else { continue }
        attributed.addAttributes([
          .backgroundColor: highlight.color,
          .foregroundColor: NSColor.labelColor
        ], range: highlight.range)
      }

      return attributed
    }

    private func collapsedDisplayValue(for column: Column,
                                       row: Int,
                                       baseText: String,
                                       highlights: [LogLionRenderedEntry.Highlight]) -> (String, [LogLionRenderedEntry.Highlight]) {
      guard column.collapsesDuplicates,
            row > 0,
            row - 1 < renderedEntries.count else {
        return (baseText, highlights)
      }

      let previousEntry = renderedEntries[row - 1].entry
      let previousText = column.text(for: previousEntry)
      guard previousText == baseText else {
        return (baseText, highlights)
      }

      return ("", [])
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let identifier = NSUserInterfaceItemIdentifier("LogLionRowView")
      let rowView: LogLionRowView

      if let reusable = tableView.makeView(withIdentifier: identifier, owner: nil) as? LogLionRowView {
        rowView = reusable
      } else {
        rowView = LogLionRowView()
        rowView.identifier = identifier
      }

      if row >= 0, row < renderedEntries.count {
        rowView.highlightColor = renderedEntries[row].rowHighlightColor
      } else {
        rowView.highlightColor = nil
      }

      return rowView
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
      guard let rowView = rowView as? LogLionRowView else { return }
      if row >= 0, row < renderedEntries.count {
        rowView.highlightColor = renderedEntries[row].rowHighlightColor
      } else {
        rowView.highlightColor = nil
      }
    }

    private func contextMenu(forRow row: Int, columnIndex: Int) -> NSMenu? {
      guard let tableView,
            row >= 0,
            row < renderedEntries.count,
            columnIndex >= 0,
            columnIndex < tableView.tableColumns.count,
            let column = Column(rawValue: tableView.tableColumns[columnIndex].identifier.rawValue),
            let field = column.filterField else {
        return nil
      }

      let entry = renderedEntries[row].entry
      let value = column.text(for: entry)
      guard !value.isEmpty else { return nil }

      let normalized = value
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let displayValue = normalized.isEmpty ? value : normalized
      let preview = displayValue.count > 60 ? String(displayValue.prefix(57)) + "…" : displayValue
      let menu = NSMenu()

      let includeTitle = "Filter In \(column.title): \"\(preview)\""
      let includeItem = NSMenuItem(title: includeTitle, action: #selector(applyFilterMenuItem(_:)), keyEquivalent: "")
      includeItem.target = self
      includeItem.representedObject = FilterMenuContext(action: .include, field: field, value: value)
      menu.addItem(includeItem)

      let excludeTitle = "Filter Out \(column.title): \"\(preview)\""
      let excludeItem = NSMenuItem(title: excludeTitle, action: #selector(applyFilterMenuItem(_:)), keyEquivalent: "")
      excludeItem.target = self
      excludeItem.representedObject = FilterMenuContext(action: .exclude, field: field, value: value)
      menu.addItem(excludeItem)

      let hideTitle = "Hide \(column.title) Column"
      let hideItem = NSMenuItem(title: hideTitle, action: #selector(hideColumnFromRowMenu(_:)), keyEquivalent: "")
      hideItem.target = self
      hideItem.representedObject = column.rawValue
      let visibleCount = Column.allCases.count - hiddenColumns.count
      hideItem.isEnabled = !hiddenColumns.contains(column) && visibleCount > 1
      menu.addItem(hideItem)

      menu.addItem(.separator())

      let copyTitle = "Copy to Clipboard"
      let copyItem = NSMenuItem(title: copyTitle, action: #selector(copyCellValue(_:)), keyEquivalent: "")
      copyItem.target = self
      copyItem.representedObject = value
      menu.addItem(copyItem)

      return menu
    }

    @objc private func copyCellValue(_ sender: NSMenuItem) {
      guard let value = sender.representedObject as? String else { return }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(value, forType: .string)
    }

    @objc private func hideColumnFromRowMenu(_ sender: NSMenuItem) {
      guard let rawValue = sender.representedObject as? String,
            let column = Column(rawValue: rawValue),
            !hiddenColumns.contains(column) else {
        return
      }
      let visibleCount = Column.allCases.count - hiddenColumns.count
      guard visibleCount > 1 else { return }
      hiddenColumns.insert(column)
      applyColumnVisibility()
    }

    private func columnVisibilityMenu(for columnIndex: Int) -> NSMenu? {
      _ = columnIndex
      guard tableView != nil else { return nil }
      let menu = NSMenu()
      let visibleCount = Column.allCases.count - hiddenColumns.count

      for column in Column.allCases {
        let item = NSMenuItem(
          title: column.title,
          action: #selector(toggleColumnVisibility(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.state = hiddenColumns.contains(column) ? .off : .on
        item.representedObject = column.rawValue
        if !hiddenColumns.contains(column) && visibleCount <= 1 {
          item.isEnabled = false
        }
        menu.addItem(item)
      }

      return menu
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
      guard let rawValue = sender.representedObject as? String,
            let column = Column(rawValue: rawValue) else {
        return
      }

      if hiddenColumns.contains(column) {
        hiddenColumns.remove(column)
      } else {
        let visibleCount = Column.allCases.count - hiddenColumns.count
        guard visibleCount > 1 else { return }
        hiddenColumns.insert(column)
      }

      applyColumnVisibility()
      tableView?.reloadData()
    }

    private func applyColumnVisibility() {
      guard let tableView else { return }

      for existing in tableView.tableColumns {
        guard let column = Column(rawValue: existing.identifier.rawValue) else { continue }
        if hiddenColumns.contains(column) {
          tableView.removeTableColumn(existing)
        }
      }

      let desiredColumns = Column.allCases.filter { !hiddenColumns.contains($0) }
      guard !desiredColumns.isEmpty else { return }

      for (targetIndex, column) in desiredColumns.enumerated() {
        let currentIndex = tableView.column(withIdentifier: column.identifier)
        if currentIndex != -1 {
          if currentIndex != targetIndex {
            tableView.moveColumn(currentIndex, toColumn: targetIndex)
          }
          continue
        }

        let newColumn = makeTableColumn(for: column)
        tableView.addTableColumn(newColumn)
        let newIndex = tableView.column(withIdentifier: column.identifier)
        if newIndex != targetIndex, newIndex != -1 {
          tableView.moveColumn(newIndex, toColumn: targetIndex)
        }
      }
    }

    private func makeTableColumn(for column: Column) -> NSTableColumn {
      let tableColumn = NSTableColumn(identifier: column.identifier)
      tableColumn.title = column.title
      tableColumn.minWidth = column.minWidth
      tableColumn.width = column.defaultWidth
      tableColumn.isEditable = false
      tableColumn.resizingMask = column.resizingMask
      tableColumn.headerCell.alignment = column.headerAlignment
      return tableColumn
    }

    @objc private func applyFilterMenuItem(_ sender: NSMenuItem) {
      guard let context = sender.representedObject as? FilterMenuContext else { return }
      onCreateFilter?(context.action, context.field, context.value)
    }

    private func scrollToBottom() {
      guard let tableView = tableView, tableView.numberOfRows > 0 else { return }
      let lastRow = tableView.numberOfRows - 1
      isProgrammaticScroll = true
      tableView.scrollRowToVisible(lastRow)
      DispatchQueue.main.async { [weak self] in
        self?.isProgrammaticScroll = false
      }
    }

    private func isViewAtBottom() -> Bool {
      guard let tableView, let scrollView else { return true }
      let contentHeight = tableView.bounds.height
      let visibleMaxY = scrollView.contentView.bounds.maxY
      return visibleMaxY >= contentHeight - 4
    }

    private func handleScrollInteraction() {
      guard !isProgrammaticScroll,
            isPinnedToBottom,
            renderedEntries.isEmpty == false else {
        return
      }

      isPinnedToBottom = false
      onScrollInteraction?()
    }

    @objc private func clipViewDidChangeBounds(_ notification: Notification) {
      handleScrollInteraction()
    }

    @objc private func columnDidResize(_ notification: Notification) {
      guard isSoftWrapEnabled,
            let tableView,
            tableView.numberOfRows > 0 else {
        return
      }
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }
  }
}

// MARK: - Column definitions

private extension LogLionEntriesTableView {
  enum Column: String, CaseIterable {
    case timestamp
    case pid
    case tid
    case level
    case tag
    case message

    static let defaultRowHeight: CGFloat = 28
    static let verticalInset: CGFloat = 4

    var identifier: NSUserInterfaceItemIdentifier {
      NSUserInterfaceItemIdentifier(rawValue)
    }

    var cellIdentifier: NSUserInterfaceItemIdentifier {
      NSUserInterfaceItemIdentifier(rawValue + ".cell")
    }

    var title: String {
      switch self {
      case .timestamp: "Time"
      case .pid: "PID"
      case .tid: "TID"
      case .level: "Lvl"
      case .tag: "Tag"
      case .message: "Message"
      }
    }

    var minWidth: CGFloat {
      switch self {
      case .timestamp: 120
      case .pid, .tid: 60
      case .level: 60
      case .tag: 120
      case .message: 200
      }
    }

    var defaultWidth: CGFloat {
      switch self {
      case .timestamp: 140
      case .pid: 70
      case .tid: 70
      case .level: 60
      case .tag: 160
      case .message: 400
      }
    }

    var resizingMask: NSTableColumn.ResizingOptions {
      switch self {
      case .message:
        [.userResizingMask, .autoresizingMask]
      default:
        .userResizingMask
      }
    }

    var alignment: NSTextAlignment {
      switch self {
      case .level, .pid, .tid:
        .center
      default:
        .left
      }
    }

    var headerAlignment: NSTextAlignment {
      switch self {
      case .level, .pid, .tid:
        .center
      default:
        .left
      }
    }

    var leadingPadding: CGFloat {
      switch self {
      case .timestamp, .tag, .message:
        8
      default:
        6
      }
    }

    var trailingPadding: CGFloat {
      switch self {
      case .message:
        12
      default:
        6
      }
    }

    static var messageFont: NSFont {
      NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    var font: NSFont {
      switch self {
      case .timestamp:
        NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      case .pid, .tid:
        NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      case .level:
        NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
      case .tag:
        NSFont.systemFont(ofSize: 12, weight: .medium)
      case .message:
        Self.messageFont
      }
    }

    var defaultTextColor: NSColor {
      switch self {
      case .level:
        NSColor.secondaryLabelColor
      default:
        NSColor.labelColor
      }
    }

    var horizontalPadding: CGFloat {
      leadingPadding + trailingPadding
    }

    func textColor(for entry: LogLionEntry) -> NSColor {
      switch self {
      case .message:
        return nsColor(for: entry.level)
      default:
        return defaultTextColor
      }
    }

    var verticalPadding: CGFloat {
      Column.verticalInset * 2
    }

    func lineBreakMode(softWrap: Bool) -> NSLineBreakMode {
      switch self {
      case .message:
        softWrap ? .byWordWrapping : .byTruncatingTail
      default:
        .byTruncatingTail
      }
    }

    func maximumNumberOfLines(softWrap: Bool) -> Int {
      switch self {
      case .message:
        softWrap ? 0 : 1
      default:
        1
      }
    }

    func usesSingleLineMode(softWrap: Bool) -> Bool {
      switch self {
      case .message:
        !softWrap
      default:
        true
      }
    }

    func text(for entry: LogLionEntry) -> String {
      switch self {
      case .timestamp:
        entry.timestampString
      case .pid:
        entry.pid.map(String.init) ?? "-"
      case .tid:
        entry.tid.map(String.init) ?? "-"
      case .level:
        entry.level.rawValue
      case .tag:
        entry.tag
      case .message:
        entry.message
      }
    }

    @MainActor
    func tableColumn(in tableView: NSTableView) -> NSTableColumn? {
      tableView.tableColumns.first { $0.identifier == identifier }
    }

    var filterField: LogLionFilterField? {
      switch self {
      case .timestamp:
        return .timestamp
      case .pid:
        return .pid
      case .tid:
        return .tid
      case .level:
        return .level
      case .tag:
        return .tag
      case .message:
        return .message
      }
    }

    var collapsesDuplicates: Bool {
      switch self {
      case .tag, .pid, .tid, .level:
        return true
      default:
        return false
      }
    }
  }
}

private func nsColor(for level: LogLionLevel) -> NSColor {
  switch level {
  case .fatal, .error:
    NSColor.systemRed
  case .warn:
    NSColor.systemOrange
  case .info:
    NSColor.systemGreen
  case .debug, .verbose:
    NSColor.systemBlue
  case .assert:
    NSColor.systemPurple
  case .unknown:
    NSColor.labelColor
  }
}

private final class LogLionRowView: NSTableRowView {
  var highlightColor: NSColor? {
    didSet { needsDisplay = true }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    if !isSelected, let color = highlightColor {
      color.setFill()
      dirtyRect.fill()
    } else {
      super.drawBackground(in: dirtyRect)
    }
  }

  override func drawSelection(in dirtyRect: NSRect) {
    if selectionHighlightStyle != .none, isSelected {
      super.drawSelection(in: dirtyRect)
    } else {
      drawBackground(in: dirtyRect)
    }
  }
}

private final class LogLionTableView: NSTableView {
  var menuProvider: ((Int, Int) -> NSMenu?)?

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    let column = column(at: point)
    if let menu = menuProvider?(row, column) {
      if row >= 0 {
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      }
      return menu
    }
    return super.menu(for: event)
  }
}

private final class LogLionTableHeaderView: NSTableHeaderView {
  var menuProvider: ((Int) -> NSMenu?)?

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let columnIndex = column(at: point)
    if let menu = menuProvider?(columnIndex) {
      return menu
    }
    return super.menu(for: event)
  }
}

private final class FilterMenuContext: NSObject {
  let action: LogLionFilterAction
  let field: LogLionFilterField
  let value: String

  init(action: LogLionFilterAction, field: LogLionFilterField, value: String) {
    self.action = action
    self.field = field
    self.value = value
  }
}
