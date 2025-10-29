import AppKit
import SwiftUI

struct SelectableHeaderList: NSViewRepresentable {
  let headers: [NetworkInspectorRequestViewModel.Header]

  func makeNSView(context: Context) -> NSTextView {
    let textView = HeaderTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.linkTextAttributes = [:]
    textView.isRichText = false
    textView.importsGraphics = false

    let attributedString = makeHeaderAttributedString(headers: headers)
    textView.textStorage?.setAttributedString(attributedString)
    return textView
  }

  func updateNSView(_ textView: NSTextView, context: Context) {
    let previousSelection = textView.selectedRange()

    let attributedString = makeHeaderAttributedString(headers: headers)
    textView.textStorage?.setAttributedString(attributedString)

    let length = attributedString.length
    let clampedLocation = min(previousSelection.location, length)
    let remainingLength = max(length - clampedLocation, 0)
    let clampedLength = min(previousSelection.length, remainingLength)
    textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView textView: NSTextView,
    context: Context
  ) -> CGSize? {
    guard let textContainer = textView.textContainer,
          let layoutManager = textView.layoutManager else {
      return .zero
    }

    let widthForContainer: CGFloat = switch proposal.width {
    case 0: 300
    default: proposal.width ?? CGFloat.greatestFiniteMagnitude
    }

    let boundingSize = NSSize(width: widthForContainer, height: .greatestFiniteMagnitude)

    let oldSize = textContainer.size
    textContainer.size = boundingSize
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    textContainer.size = oldSize

    return CGSize(width: ceil(used.width), height: ceil(used.height))
  }
}

private final class HeaderTextView: NSTextView {
  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    let nsRange = selectedRange()
    guard let range = Range(nsRange, in: string) else {
      return super.writeSelection(to: pboard, types: types)
    }

    let rawText = String(string[range])
    let normalized = normalizeCopiedText(rawText)

    pboard.declareTypes([.string], owner: nil)
    return pboard.setString(normalized, forType: .string)
  }

  override func mouseDown(with event: NSEvent) {
    var characterIndex: Int?
    if event.clickCount >= 3,
       let layoutManager,
       let textContainer {
      let pointInView = convert(event.locationInWindow, from: nil)
      let containerPoint = NSPoint(
        x: pointInView.x - textContainerInset.width,
        y: pointInView.y - textContainerInset.height
      )
      let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
      characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    super.mouseDown(with: event)

    guard event.clickCount >= 3, let characterIndex else { return }
    adjustTripleClickSelection(at: characterIndex)
  }

  private func adjustTripleClickSelection(at characterIndex: Int) {
    let nsString = string as NSString
    let lineRange = nsString.lineRange(for: NSRange(location: characterIndex, length: 0))
    guard lineRange.length > 0 else { return }

    var selectionRange = lineRange

    // Exclude trailing newline from the range if present.
    var lineEnd = lineRange.location + lineRange.length
    if lineEnd > lineRange.location, nsString.character(at: lineEnd - 1) == 0x0A {
      lineEnd -= 1
    }

    // Handle continuation lines that begin with a tab.
    if lineRange.length > 0, nsString.character(at: lineRange.location) == 0x09 {
      let valueStart = lineRange.location + 1
      let valueLength = max(lineEnd - valueStart, 0)
      if valueLength > 0 {
        selectionRange = NSRange(location: valueStart, length: valueLength)
        setSelectedRange(selectionRange)
      }
      return
    }

    let tabRange = nsString.range(of: "\t", options: [], range: lineRange)
    guard tabRange.location != NSNotFound else { return }

    if characterIndex > tabRange.location {
      let valueStart = tabRange.location + 1
      let valueLength = max(lineEnd - valueStart, 0)
      if valueLength > 0 {
        selectionRange = NSRange(location: valueStart, length: valueLength)
        setSelectedRange(selectionRange)
      }
    } else {
      let nameLength = max(tabRange.location - lineRange.location, 0)
      if nameLength > 0 {
        selectionRange = NSRange(location: lineRange.location, length: nameLength)
        setSelectedRange(selectionRange)
      }
    }
  }
}

private func normalizeCopiedText(_ text: String) -> String {
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  var formattedLines: [String] = []

  for line in lines {
    if line.hasPrefix("\t") {
      let continuation = line.dropFirst()
      formattedLines.append("  " + continuation)
    } else if let tabIndex = line.firstIndex(of: "\t") {
      let name = line[..<tabIndex]
      let valueStart = line.index(after: tabIndex)
      let value = line[valueStart...]
      formattedLines.append("\(name): \(value)")
    } else {
      formattedLines.append(String(line))
    }
  }

  return formattedLines.joined(separator: "\n")
}

private func makeHeaderAttributedString(headers: [NetworkInspectorRequestViewModel.Header]) -> NSAttributedString {
  guard !headers.isEmpty else { return NSAttributedString() }

  let captionFont = NSFont.preferredFont(forTextStyle: .caption1)
  let nameFont = NSFont.systemFont(ofSize: captionFont.pointSize, weight: .semibold)
  let valueFont = NSFont.preferredFont(forTextStyle: .body)
  let secondaryColor = NSColor.secondaryLabelColor
  let primaryColor = NSColor.labelColor

  let nameAttributes: [NSAttributedString.Key: Any] = [
    .font: nameFont,
    .foregroundColor: secondaryColor
  ]

  let valueAttributes: [NSAttributedString.Key: Any] = [
    .font: valueFont,
    .foregroundColor: primaryColor
  ]

  let widestName = headers
    .map { header -> CGFloat in
      (header.name as NSString).size(withAttributes: [.font: nameFont]).width
    }
    .max() ?? 0

  let tabLocation = widestName.rounded(.up) + 16

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: tabLocation)]
  paragraphStyle.defaultTabInterval = tabLocation
  paragraphStyle.lineSpacing = 2
  paragraphStyle.paragraphSpacing = 6
  paragraphStyle.firstLineHeadIndent = 0
  paragraphStyle.headIndent = tabLocation
  paragraphStyle.lineBreakMode = .byWordWrapping

  let result = NSMutableAttributedString()

  for (index, header) in headers.enumerated() {
    let line = NSMutableAttributedString()
    line.append(NSAttributedString(string: header.name, attributes: nameAttributes))
    line.append(NSAttributedString(string: "\t", attributes: valueAttributes))
    appendValue(header.value, to: line, valueAttributes: valueAttributes)

    if index < headers.count - 1 {
      line.append(NSAttributedString(string: "\n", attributes: valueAttributes))
    }

    line.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: line.length))
    result.append(line)
  }

  return result
}

private func appendValue(_ value: String, to line: NSMutableAttributedString, valueAttributes: [NSAttributedString.Key: Any]) {
  let components = value.split(separator: "\n", omittingEmptySubsequences: false)

  for (index, component) in components.enumerated() {
    if index > 0 {
      line.append(NSAttributedString(string: "\n\t", attributes: valueAttributes))
    }

    line.append(NSAttributedString(string: String(component), attributes: valueAttributes))
  }
}
