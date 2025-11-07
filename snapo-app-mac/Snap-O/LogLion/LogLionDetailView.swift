import SwiftUI
import AppKit

struct LogLionDetailView: View {
  @EnvironmentObject private var store: LogLionStore

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(store.activeTab?.title ?? "LogLion")
  }

  @ViewBuilder
  private var content: some View {
    if let tab = store.activeTab {
      LogLionTabContentView(tab: tab)
    } else {
      LogLionPlaceholderView(
        icon: "rectangle.stack",
        title: "Pick a Tab",
        message: "Choose a tab in the sidebar or create a new one to start streaming logs."
      )
    }
  }
}

private struct LogLionTabContentView: View {
  @ObservedObject var tab: LogLionTab
  @State private var activeFilterID: LogLionFilter.ID?
  @EnvironmentObject private var store: LogLionStore

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
            Label(tab.isFilterCollapsed ? "Expand" : "Collapse",
                  systemImage: tab.isFilterCollapsed ? "chevron.up" : "chevron.down")
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
        FiltersEditView
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
  
  
  private var FiltersEditView: some View {
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
                    LogLionFilterChip(
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
                    ),attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
                      ScrollView(.vertical, showsIndicators: true) {
                        LogLionFilterEditorView(
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
                if column.count == 1 {
                  activeFilterID = column.first!.id
                }
              }
            } label: {
              if (column.count == 1) {
                CollapsedFilterCard(
                  title: tab.columnNames[index] ?? defaultStageName(for: index, column: column),
                  filter: column.first!,
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

  private func defaultStageName(for index: Int, column: [LogLionFilter]) -> String {
    if column.count == 1, let filter = column.first {
      return filter.name
    }
    return "Stage \(index + 1)"
  }

  @ViewBuilder
  private var content: some View {
    ZStack(alignment: .top) {
      if tab.entries.isEmpty {
        LogLionPlaceholderView(
          icon: "waveform.path.ecg",
          title: "Waiting for logs…",
          message: "LogLion is streaming entries into \(tab.title). They will appear here shortly."
        )
      } else if tab.renderedEntries.isEmpty {
        LogLionPlaceholderView(
          icon: "line.3.horizontal.decrease.circle",
          title: "No matches",
          message: "Current filters hide all entries. Adjust or disable filters to see more logs."
        )
      } else {
          LogLionEntriesTableView(
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

private struct LogLionPlaceholderView: View {
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
private struct LogLionFilterChip: View {
  @ObservedObject var filter: LogLionFilter
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



private extension LogLionFilterChip {
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
    Button(action: action) {
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
  let filter: LogLionFilter
  var onToggle: () -> Void

   
  var body: some View {
    HStack(alignment: .center) {
      Spacer()
      Text(title)
        .fontWeight(.semibold)
        .lineLimit(1)
        .padding(EdgeInsets(top: 10,leading: 0, bottom: 10, trailing: 0))
      Toggle("",isOn: Binding(
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
  let filters: [LogLionFilter]
  var onToggle: (LogLionFilter) -> Void
  
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
      if (hovering) {
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
    .popover(isPresented:$isExpanded) {
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
        if (hovering) {
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
  @ObservedObject var filter: LogLionFilter
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

private struct LogLionFilterEditorView: View {
  @ObservedObject var filter: LogLionFilter
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
        ForEach(LogLionFilterAction.allCases) { action in
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

        LogLionFilterConditionEditor(
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

private let logLionLevelOptions: [LogLionLevel] = [
  .verbose, .debug, .info, .warn, .error, .fatal, .assert
]

private struct LogLionFilterConditionEditor: View {
  @Binding var condition: LogLionFilterCondition
  var onChange: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(condition.clauses.enumerated()), id: \.element.id) { index, _ in
        HStack(alignment: .center, spacing: 8) {
          Menu {
            ForEach(LogLionFilterField.allCases) { field in
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
                condition.clauses = [LogLionFilterCondition.Clause(field: .message, pattern: "")]
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
        condition.clauses.append(LogLionFilterCondition.Clause(field: nextSuggestedField(), pattern: ""))
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
      LogLionLevelSelector(selection: levelSelectionBinding(for: index))
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

  private func levelSelectionBinding(for index: Int) -> Binding<Set<LogLionLevel>> {
    Binding(
      get: { decodeLevels(from: condition.clauses[index]) },
      set: { newSelection in
        condition.clauses[index].pattern = regexPattern(for: newSelection)
        onChange()
      }
    )
  }

  private func decodeLevels(from clause: LogLionFilterCondition.Clause) -> Set<LogLionLevel> {
    guard clause.field == .level else { return [] }
    let uppercasePattern = clause.pattern.uppercased()
    guard !uppercasePattern.isEmpty else { return [] }
    return Set(logLionLevelOptions.filter { uppercasePattern.contains($0.rawValue) })
  }

  private func regexPattern(for selection: Set<LogLionLevel>) -> String {
    guard !selection.isEmpty else { return "" }
    let symbols = selection.map(\.rawValue).sorted()
    let body = symbols.joined(separator: "|")
    return "^(\(body))$"
  }

  private func nextSuggestedField() -> LogLionFilterField {
    let priorityOrder: [LogLionFilterField] = [.message, .tag, .level, .timestamp]
    let usedFields = Set(condition.clauses.map(\.field))
    return priorityOrder.first(where: { !usedFields.contains($0) }) ?? .message
  }
}

private struct LogLionLevelSelector: View {
  @Binding var selection: Set<LogLionLevel>

  var body: some View {
    LogLionLevelSegmentedControl(selection: $selection)
      .frame(height: 30)
  }
}

private struct LogLionLevelSegmentedControl: NSViewRepresentable {
  @Binding var selection: Set<LogLionLevel>

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: logLionLevelOptions.map(\.description),
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
    for (index, level) in logLionLevelOptions.enumerated() {
      control.setLabel(level.description, forSegment: index)
      control.setSelected(selection.contains(level), forSegment: index)
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    var selection: Binding<Set<LogLionLevel>>

    init(selection: Binding<Set<LogLionLevel>>) {
      self.selection = selection
    }

    @objc func valueChanged(_ sender: NSSegmentedControl) {
      var updated: Set<LogLionLevel> = []
      for (index, level) in logLionLevelOptions.enumerated() {
        if sender.isSelected(forSegment: index) {
          updated.insert(level)
        }
      }
      selection.wrappedValue = updated
    }
  }
}
