import AppKit
import SwiftUI

struct SelectableHeaderList: NSViewRepresentable {
  let headers: [NetworkInspectorRequestViewModel.Header]

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.linkTextAttributes = [:]
    let attributedString = makeHeaderAttributedString(headers: headers)
    textView.textStorage?.setAttributedString(attributedString)
    return textView
  }

  func updateNSView(_ textView: NSTextView, context: Context) {
    let previousSelection = textView.selectedRange()
    textView.textContainer?.lineFragmentPadding = 0

    let attributedString = makeHeaderAttributedString(headers: headers)
    textView.textStorage?.setAttributedString(attributedString)

    let length = attributedString.length
    let clampedLocation = min(previousSelection.location, length)
    let remainingLength = max(length - clampedLocation, 0)
    let clampedLength = min(previousSelection.length, remainingLength)
    textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let textStorage = nsView.textStorage else {
      return CGSize(width: proposal.width ?? 0, height: 0)
    }

    let boundingSize = NSSize(
      width: proposal.width ?? CGFloat.greatestFiniteMagnitude,
      height: proposal.height ?? CGFloat.greatestFiniteMagnitude
    )
    let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    let attributedString = NSAttributedString(attributedString: textStorage)
    let measuredRect = attributedString.boundingRect(with: boundingSize, options: options)

    let measuredHeight = ceil(measuredRect.height)
    let measuredWidth = ceil(measuredRect.width)
    let size = CGSize(width: measuredWidth, height: measuredHeight)

    return size
  }
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
