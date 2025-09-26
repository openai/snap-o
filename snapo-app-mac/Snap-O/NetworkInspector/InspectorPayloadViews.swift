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
  @State private var isExpanded = false
  @State private var fullHeight: CGFloat = .zero

  init(text: String, font: Font, maximumHeight: CGFloat = 100) {
    self.text = text
    self.font = font
    self.maximumHeight = maximumHeight
  }

  private var needsExpansion: Bool {
    fullHeight > maximumHeight + 1
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      textView()

      if needsExpansion {
        Button(isExpanded ? "Show Less" : "Show More") {
          withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
          }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    }
    .overlay(HeightReader(text: text, font: font))
    .onPreferenceChange(TextHeightPreferenceKey.self) { newValue in
      let adjusted = newValue
      if abs(fullHeight - adjusted) > 0.5 || fullHeight == .zero {
        fullHeight = adjusted
      }
      if fullHeight <= maximumHeight + 1 {
        isExpanded = false
      }
    }
  }

  @ViewBuilder
  private func textView() -> some View {
    if !isExpanded, needsExpansion {
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
      Text(text)
        .font(font)
        .fixedSize(horizontal: false, vertical: true)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(key: TextHeightPreferenceKey.self, value: proxy.size.height)
          }
        )
        .frame(width: 0, height: 0)
        .opacity(0)
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
  @Binding private var usePrettyPrinted: Bool

  init(
    rawText: String,
    prettyText: String?,
    isLikelyJSON: Bool,
    usePrettyPrinted: Binding<Bool>,
    maximumHeight: CGFloat = 100,
    showsToggle: Bool = true
  ) {
    self.rawText = rawText
    self.prettyText = prettyText
    self.isLikelyJSON = isLikelyJSON
    self.maximumHeight = maximumHeight
    self.showsToggle = showsToggle
    _usePrettyPrinted = usePrettyPrinted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showsToggle, prettyText != nil {
        Toggle("Pretty print", isOn: $usePrettyPrinted)
          .font(.caption)
          .toggleStyle(.checkbox)
      } else if prettyText == nil, isLikelyJSON {
        Text("Unable to pretty print (invalid or truncated JSON)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      InspectorExpandableText(
        text: displayText,
        font: .callout.monospaced(),
        maximumHeight: maximumHeight
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var displayText: String {
    if usePrettyPrinted, let pretty = prettyText {
      return pretty
    }
    return rawText
  }
}
