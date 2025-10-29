import SwiftUI

struct InspectorCard<Content: View>: View {
  @ViewBuilder private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      content
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.secondary.opacity(0.05))
    )
  }
}

struct InspectorExpandableText: View {
  let text: String
  let font: Font
  let maximumHeight: CGFloat
  private let externalIsExpanded: Binding<Bool>?
  @State private var internalIsExpanded = false
  @State private var fullHeight: CGFloat = .zero

  init(text: String, font: Font, maximumHeight: CGFloat = 100, isExpanded: Binding<Bool>? = nil) {
    self.text = text
    self.font = font
    self.maximumHeight = maximumHeight
    externalIsExpanded = isExpanded
    _internalIsExpanded = State(initialValue: isExpanded?.wrappedValue ?? false)
  }

  private var isExpandedBinding: Binding<Bool> {
    externalIsExpanded ?? $internalIsExpanded
  }

  private var needsExpansion: Bool {
    fullHeight > maximumHeight + 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      textView()

      if needsExpansion {
        Button(isExpandedBinding.wrappedValue ? "Show Less" : "Show More") {
          withAnimation(.easeInOut(duration: 0.2)) {
            isExpandedBinding.wrappedValue.toggle()
          }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    }
    .background(HeightReader(text: text, font: font))
    .onPreferenceChange(TextHeightPreferenceKey.self) { newValue in
      let adjusted = newValue
      if abs(fullHeight - adjusted) > 0.5 || fullHeight == .zero {
        fullHeight = adjusted
      }
      if fullHeight <= maximumHeight + 1 {
        if !needsExpansion {
          isExpandedBinding.wrappedValue = false
        }
      }
    }
  }

  @ViewBuilder
  private func textView() -> some View {
    if !isExpandedBinding.wrappedValue, needsExpansion {
      Text(text)
        .font(font)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: maximumHeight, alignment: .top)
        .clipped()
    } else {
      Text(text)
        .font(font)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private struct HeightReader: View {
    let text: String
    let font: Font

    var body: some View {
      GeometryReader { geometry in
        let width = geometry.size.width
        Group {
          if width > 0 {
            Text(text)
              .font(font)
              .frame(width: width, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .background(
                GeometryReader { proxy in
                  Color.clear.preference(key: TextHeightPreferenceKey.self, value: proxy.size.height)
                }
              )
              .hidden()
          } else {
            Color.clear
          }
        }
        .allowsHitTesting(false)
      }
      .allowsHitTesting(false)
    }
  }

  private struct TextHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = max(value, nextValue())
    }
  }
}

struct InspectorPayloadView: View {
  let rawText: String
  let prettyText: String?
  let isLikelyJSON: Bool
  let maximumHeight: CGFloat
  let showsToggle: Bool
  let showsCopyButton: Bool
  let isExpandable: Bool
  let embedControlsInJSON: Bool
  private let expandedBinding: Binding<Bool>?
  private let jsonOutlineRoot: JSONOutlineNode?
  private let prettyInitiallyExpanded: Bool
  @Binding private var usePrettyPrinted: Bool
  @State private var localPrettyPrinted: Bool

  init(
    rawText: String,
    prettyText: String?,
    isLikelyJSON: Bool,
    usePrettyPrinted: Binding<Bool>,
    maximumHeight: CGFloat = 100,
    showsToggle: Bool = true,
    showsCopyButton: Bool = true,
    isExpandable: Bool = true,
    embedControlsInJSON: Bool = false,
    expandedBinding: Binding<Bool>? = nil,
    prettyInitiallyExpanded: Bool = true
  ) {
    self.rawText = rawText
    self.prettyText = prettyText
    self.isLikelyJSON = isLikelyJSON
    self.maximumHeight = maximumHeight
    self.showsToggle = showsToggle
    self.showsCopyButton = showsCopyButton
    self.isExpandable = isExpandable
    self.embedControlsInJSON = embedControlsInJSON
    self.expandedBinding = expandedBinding
    self.prettyInitiallyExpanded = prettyInitiallyExpanded
    if let prettyText {
      jsonOutlineRoot = JSONOutlineNode.makeTree(from: prettyText)
    } else {
      jsonOutlineRoot = nil
    }
    _usePrettyPrinted = usePrettyPrinted
    _localPrettyPrinted = State(initialValue: usePrettyPrinted.wrappedValue)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !shouldEmbedControlsInJSON {
        controlsView(includeSpacer: true)
      }

      if prettyText == nil, isLikelyJSON, !hasToggle {
        Text("Unable to pretty print (invalid or truncated JSON)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      payloadContent()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: usePrettyPrinted) {
      if usePrettyPrinted != localPrettyPrinted {
        localPrettyPrinted = usePrettyPrinted
      }
    }
    .onChange(of: localPrettyPrinted) {
      if localPrettyPrinted != usePrettyPrinted {
        usePrettyPrinted = localPrettyPrinted
      }
    }
  }

  @ViewBuilder
  private func payloadContent() -> some View {
    if localPrettyPrinted, let root = jsonOutlineRoot {
      if shouldEmbedControlsInJSON {
        JSONOutlineView(
          root: root,
          initiallyExpanded: prettyInitiallyExpanded,
          trailingControls: AnyView(controlsView(includeSpacer: false))
        )
      } else {
        JSONOutlineView(root: root, initiallyExpanded: prettyInitiallyExpanded)
      }
    } else if isExpandable {
      InspectorExpandableText(
        text: displayText,
        font: .callout.monospaced(),
        maximumHeight: maximumHeight,
        isExpanded: expandedBinding
      )
    } else {
      Text(displayText)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var displayText: String {
    if localPrettyPrinted, let pretty = prettyText {
      return pretty
    }
    return rawText
  }

  private var hasToggle: Bool {
    showsToggle && prettyText != nil
  }

  private var shouldEmbedControlsInJSON: Bool {
    embedControlsInJSON && localPrettyPrinted && jsonOutlineRoot != nil && (hasToggle || (showsCopyButton && !displayText.isEmpty))
  }

  @ViewBuilder
  private func controlsView(includeSpacer: Bool) -> some View {
    let shouldShowCopy = showsCopyButton && !displayText.isEmpty
    Group {
      if hasToggle || shouldShowCopy {
        HStack(spacing: 8) {
          if includeSpacer {
            Spacer()
          }

          if hasToggle {
            Toggle(
              "Pretty print",
              isOn: Binding(
                get: { localPrettyPrinted },
                set: { localPrettyPrinted = $0 }
              )
            )
            .font(.caption)
            .toggleStyle(.checkbox)
          }

          if shouldShowCopy {
            Button {
              NetworkInspectorCopyExporter.copyText(displayText)
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                Text("Copy")
              }
            }
            .buttonStyle(.plain)
            .font(.caption)
          }
        }
      } else {
        EmptyView()
      }
    }
  }
}
