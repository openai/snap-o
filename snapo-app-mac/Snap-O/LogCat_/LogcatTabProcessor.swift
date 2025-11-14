import Foundation

actor LogcatTabProcessor {
  typealias QuickFilter = LogcatQuickFilterSnapshot
  typealias Configuration = LogcatFilterConfigurationSnapshot

  enum Update: Sendable {
    case tabUpdate(LogcatTabUpdate)
  }

  private let capacity: Int
  private let flushIntervalNanoseconds: UInt64 = 50_000_000
  private let logger = SnapOLog.logCat
  private var deliverUpdate: (@Sendable (Update) async -> Void)?

  private var buffer: LogcatRingBuffer
  private var pendingEntries: [LogcatEntry] = []
  private var configuration: Configuration
  private var quickFilterRegex: NSRegularExpression?
  private var regexCache: [LogcatRegexCacheKey: NSRegularExpression] = [:]
  private var isProcessing = false
  private var needsFullRecompute = false
  private var pendingUpdate: LogcatTabUpdate?
  private var flushTask: Task<Void, Never>?
  private var isPaused = false
  private var renderedSnapshots: [LogcatRenderedSnapshot] = []

  init(
    capacity: Int,
    initialConfiguration: Configuration
  ) {
    self.capacity = capacity
    configuration = initialConfiguration
    buffer = LogcatRingBuffer(capacity: capacity)
    quickFilterRegex = configuration.quickFilter.flatMap { try? NSRegularExpression(pattern: $0.pattern, options: []) }
  }

  func setDeliverUpdate(_ handler: @escaping @Sendable (Update) async -> Void) {
    deliverUpdate = handler
  }

  func enqueue(_ entry: LogcatEntry) {
    guard !isPaused else { return }
    pendingEntries.append(entry)
    scheduleProcessing()
  }

  func refreshConfiguration(_ configuration: Configuration) {
    self.configuration = configuration
    quickFilterRegex = configuration.quickFilter.flatMap { try? NSRegularExpression(pattern: $0.pattern, options: []) }
    needsFullRecompute = true
    scheduleProcessing()
  }

  func reset() {
    buffer.reset()
    pendingEntries.removeAll(keepingCapacity: true)
    pendingUpdate = nil
    flushTask?.cancel()
    flushTask = nil
    needsFullRecompute = true
    renderedSnapshots.removeAll(keepingCapacity: true)
    scheduleProcessing()
  }

  func setPaused(_ value: Bool) {
    isPaused = value
  }

  private func scheduleProcessing() {
    guard !isProcessing else { return }
    isProcessing = true
    Task(priority: .userInitiated) { await self.processPending() }
  }

  private func processPending() async {
    while true {
      let entries = pendingEntries
      let shouldRecompute = needsFullRecompute || !entries.isEmpty

      guard shouldRecompute else {
        isProcessing = false
        return
      }

      pendingEntries.removeAll(keepingCapacity: true)
      let didReset = needsFullRecompute
      needsFullRecompute = false

      var droppedEntries: [LogcatEntry] = []
      droppedEntries.reserveCapacity(entries.count)
      for entry in entries {
        if let dropped = buffer.append(entry) {
          droppedEntries.append(dropped)
        }
      }

      let dropped = buffer.consumeDropCount()

      if !droppedEntries.isEmpty {
        var droppedIDs = Set(droppedEntries.map(\.id))
        while let first = renderedSnapshots.first,
              droppedIDs.contains(first.entry.id) {
          droppedIDs.remove(first.entry.id)
          renderedSnapshots.removeFirst()
        }

        if !droppedIDs.isEmpty {
          let problematicSnapshot = renderedSnapshots.first { droppedIDs.contains($0.entry.id) }
          if problematicSnapshot != nil {
            logger.error("LogcatTabProcessor detected dropped snapshot mismatch, scheduling full recompute.")
            needsFullRecompute = true
            continue
          }
          // Remaining IDs correspond to entries that never rendered, so no snapshot cleanup is needed.
        }
      }

      let newEntryIDs = Set(entries.map(\.id))
      var renderedDelta = 0

      if didReset {
        let retainedEntries = buffer.all
        renderedSnapshots = render(entries: retainedEntries)
        if !newEntryIDs.isEmpty {
          renderedDelta = renderedSnapshots.reduce(into: 0) { result, snapshot in
            if newEntryIDs.contains(snapshot.entry.id) {
              result += 1
            }
          }
        }
      } else {
        let newlyRendered = render(entries: entries)
        if !newlyRendered.isEmpty {
          renderedSnapshots.append(contentsOf: newlyRendered)
        }
        renderedDelta = newlyRendered.count
      }

      let rendered = renderedSnapshots
      let entryCount = buffer.currentCount
      let metrics = LogcatTabMetrics(
        unreadDelta: renderedDelta,
        droppedEntries: dropped
      )
      var errors: [LogcatTabError] = []
      if dropped > 100 {
        errors.append(.backlogDropped(droppedCount: dropped))
      }
      if entries.count > 10 {
        errors.append(.slowProcessing(count: entries.count))
      }
      let update = LogcatTabUpdate(
        entryCount: entryCount,
        renderedEntries: rendered,
        metrics: metrics,
        errors: errors,
        didReset: didReset,
        isPinnedToBottomHint: nil
      )
      pendingUpdate = update
      scheduleFlush()
    }
  }

  private func render(entries: [LogcatEntry]) -> [LogcatRenderedSnapshot] {
    guard !entries.isEmpty else { return [] }

    let quickFilteredEntries: [LogcatEntry] = if let quickFilterRegex {
      entries.filter { entry in
        let nsString = entry.raw as NSString
        let range = NSRange(location: 0, length: nsString.length)
        return quickFilterRegex.firstMatch(in: entry.raw, options: [], range: range) != nil
      }
    } else {
      entries
    }

    guard !quickFilteredEntries.isEmpty else { return [] }

    let columns = configuration.filters.filter { !$0.isEmpty }
    guard !columns.isEmpty else {
      return quickFilteredEntries.map { LogcatRenderedSnapshot(entry: $0) }
    }

    var processed: [LogcatRenderedSnapshot] = []
    processed.reserveCapacity(quickFilteredEntries.count)

    for entry in quickFilteredEntries {
      var isExcluded = false
      var columnFailure = false
      var rowColor: LogcatColor?
      var fieldHighlights: [LogcatFilterField: [LogcatColorHighlight]] = [:]

      columnLoop: for column in columns {
        let includeFilters = column.filter { $0.action == .include }
        var columnIncludeMatched = includeFilters.isEmpty

        for filter in column {
          let result = filter.evaluate(entry: entry, regexCache: &regexCache)
          guard result.isMatch else { continue }

          switch filter.action {
          case .include:
            columnIncludeMatched = true
          case .exclude:
            isExcluded = true
          case .none:
            break
          }

          guard !isExcluded else { break columnLoop }

          if filter.isHighlightEnabled {
            let baseColor = filter.color
            let background = baseColor.withAlpha(0.08)
            if let existing = rowColor {
              rowColor = existing.blended(with: background, fraction: 0.5)
            } else {
              rowColor = background
            }

            let highlightColor = baseColor.withAlpha(0.35)
            for (field, ranges) in result.fieldRanges where field != .raw {
              let highlights = ranges.map { LogcatColorHighlight(range: $0, color: highlightColor) }
              fieldHighlights[field, default: []].append(contentsOf: highlights)
            }
          }
        }

        guard columnIncludeMatched else {
          columnFailure = true
          break
        }
      }

      guard !isExcluded, !columnFailure else { continue }

      processed.append(
        LogcatRenderedSnapshot(
          entry: entry,
          rowHighlightColor: rowColor,
          fieldHighlights: fieldHighlights
        )
      )
    }

    return processed
  }

  private func scheduleFlush() {
    guard flushTask == nil else { return }
    let interval = flushIntervalNanoseconds
    flushTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: interval)
      } catch {
        return
      }
      await flushPendingUpdate()
    }
  }

  private func flushPendingUpdate() async {
    flushTask = nil
    guard let update = pendingUpdate else { return }
    pendingUpdate = nil
    if let deliverUpdate {
      await deliverUpdate(.tabUpdate(update))
    }
    if pendingUpdate != nil {
      scheduleFlush()
    }
  }
}
