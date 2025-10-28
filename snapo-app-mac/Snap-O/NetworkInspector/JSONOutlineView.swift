import SwiftUI
import AppKit

struct JSONOutlineNode: Identifiable {
  enum Value {
    case object([JSONOutlineNode])
    case array([JSONOutlineNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
  }

  let id: String
  let path: String
  let key: String?
  let value: Value

  static func makeTree(from text: String) -> JSONOutlineNode? {
    var parser = JSONParser(text: text)
    return try? parser.parseRoot()
  }

  init(key: String?, path: String, value: Value) {
    self.key = key
    self.path = path
    id = path
    self.value = value
  }
}

struct JSONOutlineView: View {
  let root: JSONOutlineNode
  @State private var expandedNodes: Set<String>
  @State private var expandedStrings: Set<String>

  init(root: JSONOutlineNode, initiallyExpanded: Bool = true) {
    self.root = root
    _expandedNodes = State(initialValue: initiallyExpanded ? Set([root.id]) : Set<String>())
    _expandedStrings = State(initialValue: Set<String>())
  }

  init?(text: String, initiallyExpanded: Bool = true) {
    guard let node = JSONOutlineNode.makeTree(from: text) else { return nil }
    self.init(root: node, initiallyExpanded: initiallyExpanded)
  }

  var body: some View {
    JSONOutlineNodeView(
      node: root,
      expandedNodes: $expandedNodes,
      expandedStrings: $expandedStrings
    )
    .font(.callout.monospaced())
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct JSONOutlineNodeView: View {
  let node: JSONOutlineNode
  @Binding var expandedNodes: Set<String>
  @Binding var expandedStrings: Set<String>

  init(
    node: JSONOutlineNode,
    expandedNodes: Binding<Set<String>>,
    expandedStrings: Binding<Set<String>>
  ) {
    self.node = node
    _expandedNodes = expandedNodes
    _expandedStrings = expandedStrings
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch node.value {
      case let .object(children):
        compositeView(children: children, openSymbol: "{", closeSymbol: "}")
      case let .array(children):
        compositeView(children: children, openSymbol: "[", closeSymbol: "]")
      case let .string(value):
        stringValueView(value: value)
      case let .number(value):
        valueLabel(content: Text(value).foregroundColor(.blue))
      case let .bool(value):
        valueLabel(content: Text(value ? "true" : "false").foregroundColor(.blue))
      case .null:
        valueLabel(content: Text("null").foregroundColor(.secondary))
      }
    }
    .textSelection(.enabled)
    .contextMenu { nodeContextMenu }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func compositeView(children: [JSONOutlineNode], openSymbol: String, closeSymbol: String) -> some View {
    if children.isEmpty {
      collapsedLabel()
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Button(action: toggleExpanded) {
          HStack(alignment: .top, spacing: 4) {
            triangleIndicator
            (isExpanded ? expandedHeader(openSymbol: openSymbol) : collapsedHeader())
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)

        if isExpanded {
          ForEach(children) { child in
            JSONOutlineNodeView(
              node: child,
              expandedNodes: $expandedNodes,
              expandedStrings: $expandedStrings
            )
            .padding(.leading, 12)
          }
          closingLine(closeSymbol: closeSymbol)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func valueLabel(content: Text) -> some View {
    let text = (keyLabel ?? Text("")) + content
    return HStack(alignment: .top, spacing: 4) {
      trianglePlaceholder
      text
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func collapsedLabel() -> some View {
    let text = collapsedHeader()
    return HStack(alignment: .top, spacing: 4) {
      triangleIndicator
      text
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture {
      if node.isExpandable {
        toggleExpanded()
      }
    }
  }

  private func closingLine(closeSymbol: String) -> some View {
    let text = Text(closeSymbol)
    return HStack(alignment: .top, spacing: 4) {
      trianglePlaceholder
      text
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var triangleIndicator: some View {
    TriangleIndicator(isVisible: node.isExpandable, isExpanded: isExpanded)
  }

  private var trianglePlaceholder: some View {
    TriangleIndicator(isVisible: false, isExpanded: false)
  }

  private func collapsedHeader() -> Text {
    if let keyText = keyLabel {
      return keyText + Text(node.inlineValueDescription(maxLength: 120))
    }
    return Text(node.inlineValueDescription(maxLength: 120))
  }

  private func expandedHeader(openSymbol: String) -> Text {
    if let keyText = keyLabel {
      return keyText + Text(openSymbol)
    }
    return Text(openSymbol)
  }

  private func stringValueView(value: String) -> some View {
    let lines = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    let isCollapsible = lines.count > stringLineLimit
    let displayValue: String

    if isCollapsible && !isStringExpanded {
      let limitedLines = lines.prefix(stringLineLimit)
      let joined = limitedLines.joined(separator: "\n")
      displayValue = "\(joined)\n…"
    } else {
      displayValue = value
    }

    let valueText = Text("\"\(displayValue)\"").foregroundColor(.red)

    return VStack(alignment: .leading, spacing: 4) {
      valueLabel(content: valueText)
      if isCollapsible {
        HStack(alignment: .top, spacing: 4) {
          trianglePlaceholder
          Button(isStringExpanded ? "See less" : "See more") {
            withAnimation {
              toggleStringExpanded()
            }
          }
          .buttonStyle(.plain)
          .foregroundColor(.blue)
          .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var stringLineLimit: Int { 20 }

  private var keyLabel: Text? {
    guard let key = node.key else { return nil }
    return Text("\(key): ").foregroundColor(.purple)
  }

  private struct TriangleIndicator: View {
    let isVisible: Bool
    let isExpanded: Bool

    var body: some View {
      Group {
        if isVisible {
          Image(systemName: "triangle.fill")
            .font(.system(size: 8))
            .rotationEffect(.degrees(isExpanded ? 180 : 90))
            .foregroundColor(.primary)
            .padding(.top, 2)
        } else {
          Image(systemName: "triangle.fill")
            .font(.system(size: 8))
            .opacity(0)
            .padding(.top, 2)
        }
      }
      .frame(width: 10, alignment: .leading)
    }
  }

  private var isExpanded: Bool {
    expandedNodes.contains(node.id)
  }

  private var isStringExpanded: Bool {
    expandedStrings.contains(node.id)
  }

  @ViewBuilder
  private var nodeContextMenu: some View {
    if let valueText = node.copyValueText(prettyPrinted: true) {
      Button("Copy Value") {
        copyToPasteboard(valueText)
      }
    }

    if node.isExpandable {
      if node.copyValueText(prettyPrinted: true) != nil {
        Divider()
      }
      Button("Expand All") {
        expandAll()
      }
      Button("Collapse Children") {
        collapseChildren()
      }
    }
  }

  private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func toggleExpanded() {
    guard node.isExpandable else { return }
    if isExpanded {
      expandedNodes.remove(node.id)
    } else {
      expandedNodes.insert(node.id)
    }
  }

  private func toggleStringExpanded() {
    if isStringExpanded {
      expandedStrings.remove(node.id)
    } else {
      expandedStrings.insert(node.id)
    }
  }

  private func expandAll() {
    expandedNodes.formUnion(node.collectExpandableIDs(includeSelf: true))
  }

  private func collapseChildren() {
    expandedNodes.subtract(node.collectExpandableIDs(includeSelf: false))
    expandedStrings.subtract(node.collectStringNodeIDs(includeSelf: false))
  }
}

private extension JSONOutlineNode {
  var isExpandable: Bool {
    switch value {
    case let .object(children):
      return !children.isEmpty
    case let .array(children):
      return !children.isEmpty
    default:
      return false
    }
  }

  func collectExpandableIDs(includeSelf: Bool) -> Set<String> {
    switch value {
    case let .object(children):
      var ids: Set<String> = includeSelf && isExpandable ? Set([id]) : Set<String>()
      for child in children {
        ids.formUnion(child.collectExpandableIDs(includeSelf: true))
      }
      return ids
    case let .array(children):
      var ids: Set<String> = includeSelf && isExpandable ? Set([id]) : Set<String>()
      for child in children {
        ids.formUnion(child.collectExpandableIDs(includeSelf: true))
      }
      return ids
    default:
      return Set<String>()
    }
  }

  func collectStringNodeIDs(includeSelf: Bool) -> Set<String> {
    switch value {
    case .string:
      return includeSelf ? Set([id]) : Set<String>()
    case let .object(children):
      return children.reduce(into: Set<String>()) { result, child in
        result.formUnion(child.collectStringNodeIDs(includeSelf: true))
      }
    case let .array(children):
      return children.reduce(into: Set<String>()) { result, child in
        result.formUnion(child.collectStringNodeIDs(includeSelf: true))
      }
    default:
      return Set<String>()
    }
  }

  func copyValueText(prettyPrinted: Bool) -> String? {
    switch value {
    case .object, .array:
      guard let fragment = jsonFragmentText() else { return nil }
      guard prettyPrinted else { return fragment }
      guard
        let data = fragment.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(
          withJSONObject: json,
          options: [.prettyPrinted]
        ),
        let string = String(data: pretty, encoding: .utf8)
      else {
        return fragment
      }
      return string
    case let .string(string):
      return string
    case let .number(number):
      return number
    case let .bool(bool):
      return bool ? "true" : "false"
    case .null:
      return "null"
    }
  }

  func inlineValueDescription(maxLength: Int) -> String {
    let raw = rawInlineValueDescription()
    guard raw.count > maxLength else { return raw }
    let index = raw.index(raw.startIndex, offsetBy: max(0, maxLength - 3))
    return "\(raw[..<index])..."
  }

  private func rawInlineValueDescription() -> String {
    switch value {
    case let .object(children):
      guard !children.isEmpty else { return "{ }" }
      let inner = children.map { $0.rawInlineKeyValueDescription() }.joined(separator: ", ")
      return "{ \(inner) }"
    case let .array(children):
      guard !children.isEmpty else { return "[ ]" }
      let inner = children.map { $0.rawInlineValueDescription() }.joined(separator: ", ")
      return "[ \(inner) ]"
    case let .string(string):
      return "\"\(string.jsonEscapedSnippet())\""
    case let .number(number):
      return number
    case let .bool(value):
      return value ? "true" : "false"
    case .null:
      return "null"
    }
  }

  private func rawInlineKeyValueDescription() -> String {
    guard let key = key else {
      return rawInlineValueDescription()
    }
    let keyDisplay = key.hasPrefix("[") ? key : "\"\(key)\""
    return "\(keyDisplay): \(rawInlineValueDescription())"
  }

  private func jsonFragmentText() -> String? {
    switch value {
    case let .object(children):
      let fragments = children.compactMap { child -> String? in
        guard let key = child.key else { return nil }
        guard let valueFragment = child.jsonFragmentText() else { return nil }
        return "\"\(key.jsonEscapedForJSON())\":\(valueFragment)"
      }
      return "{\(fragments.joined(separator: ","))}"
    case let .array(children):
      let fragments = children.map { child -> String in
        child.jsonFragmentText() ?? "null"
      }
      return "[\(fragments.joined(separator: ","))]"
    case let .string(string):
      return "\"\(string.jsonEscapedForJSON())\""
    case let .number(number):
      return number
    case let .bool(bool):
      return bool ? "true" : "false"
    case .null:
      return "null"
    }
  }
}

private extension String {
  func jsonEscapedSnippet() -> String {
    var snippet = self.replacingOccurrences(of: "\"", with: "\\\"")
    snippet = snippet.replacingOccurrences(of: "\n", with: "\\n")
    snippet = snippet.replacingOccurrences(of: "\t", with: "\\t")
    return snippet
  }

  func jsonEscapedForJSON() -> String {
    var result = ""
    result.reserveCapacity(count)
    for scalar in unicodeScalars {
      switch scalar.value {
      case 0x22: result.append("\\\"")
      case 0x5C: result.append("\\\\")
      case 0x08: result.append("\\b")
      case 0x0C: result.append("\\f")
      case 0x0A: result.append("\\n")
      case 0x0D: result.append("\\r")
      case 0x09: result.append("\\t")
      case 0x00...0x1F:
        result.append(String(format: "\\u%04X", scalar.value))
      default:
        result.append(String(scalar))
      }
    }
    return result
  }
}

private struct JSONParser {
  enum ParserError: Error {
    case unexpectedEndOfInput
    case invalidCharacter(Character)
    case invalidNumber
    case invalidUnicodeEscape
    case trailingCharacters
  }

  private let text: String
  private var index: String.Index

  init(text: String) {
    self.text = text
    self.index = text.startIndex
  }

  mutating func parseRoot() throws -> JSONOutlineNode {
    skipWhitespace()
    let node = try parseValue(withKey: nil, path: "$")
    skipWhitespace()
    guard isAtEnd else { throw ParserError.trailingCharacters }
    return node
  }

  private mutating func parseValue(withKey key: String?, path: String) throws -> JSONOutlineNode {
    guard let character = peek() else { throw ParserError.unexpectedEndOfInput }
    switch character {
    case "{":
      return try parseObject(withKey: key, path: path)
    case "[":
      return try parseArray(withKey: key, path: path)
    case "\"":
      let string = try parseStringLiteral()
      return JSONOutlineNode(key: key, path: path, value: .string(string))
    case "-", "0"..."9":
      let number = try parseNumberLiteral()
      return JSONOutlineNode(key: key, path: path, value: .number(number))
    case "t":
      try expectLiteral("true")
      return JSONOutlineNode(key: key, path: path, value: .bool(true))
    case "f":
      try expectLiteral("false")
      return JSONOutlineNode(key: key, path: path, value: .bool(false))
    case "n":
      try expectLiteral("null")
      return JSONOutlineNode(key: key, path: path, value: .null)
    default:
      throw ParserError.invalidCharacter(character)
    }
  }

  private mutating func parseObject(withKey key: String?, path: String) throws -> JSONOutlineNode {
    try expect("{")
    skipWhitespace()
    var children: [JSONOutlineNode] = []

    if match("}") {
      return JSONOutlineNode(key: key, path: path, value: .object(children))
    }

    while true {
      skipWhitespace()
      let childKey = try parseStringLiteral()
      skipWhitespace()
      try expect(":")
      skipWhitespace()
      let childPath: String
      if path == "$" {
        childPath = "$.\(childKey)"
      } else {
        childPath = "\(path).\(childKey)"
      }
      let child = try parseValue(withKey: childKey, path: childPath)
      children.append(child)
      skipWhitespace()
      if match("}") {
        break
      }
      try expect(",")
      skipWhitespace()
    }

    return JSONOutlineNode(key: key, path: path, value: .object(children))
  }

  private mutating func parseArray(withKey key: String?, path: String) throws -> JSONOutlineNode {
    try expect("[")
    skipWhitespace()
    var children: [JSONOutlineNode] = []

    if match("]") {
      return JSONOutlineNode(key: key, path: path, value: .array(children))
    }

    var indexCounter = 0
    while true {
      skipWhitespace()
      let childKey = "[\(indexCounter)]"
      let childPath: String
      if path == "$" {
        childPath = "$\(childKey)"
      } else {
        childPath = "\(path)\(childKey)"
      }
      let child = try parseValue(withKey: childKey, path: childPath)
      children.append(child)
      indexCounter += 1
      skipWhitespace()
      if match("]") {
        break
      }
      try expect(",")
      skipWhitespace()
    }

    return JSONOutlineNode(key: key, path: path, value: .array(children))
  }

  private mutating func parseStringLiteral() throws -> String {
    try expect("\"")
    var result = ""
    while let character = advance() {
      switch character {
      case "\"":
        return result
      case "\\":
        guard let escaped = try parseEscapedCharacter() else { throw ParserError.invalidUnicodeEscape }
        result.append(escaped)
      default:
        result.append(character)
      }
    }
    throw ParserError.unexpectedEndOfInput
  }

  private mutating func parseEscapedCharacter() throws -> Character? {
    guard let character = advance() else { throw ParserError.unexpectedEndOfInput }
    switch character {
    case "\"": return "\""
    case "\\": return "\\"
    case "/": return "/"
    case "b": return "\u{08}"
    case "f": return "\u{0C}"
    case "n": return "\n"
    case "r": return "\r"
    case "t": return "\t"
    case "u":
      let scalar = try parseUnicodeScalar()
      return Character(scalar)
    default:
      throw ParserError.invalidUnicodeEscape
    }
  }

  private mutating func parseUnicodeScalar() throws -> UnicodeScalar {
    let hex = try readHexDigits(count: 4)
    guard let value = UInt32(hex, radix: 16) else { throw ParserError.invalidUnicodeEscape }

    if (0xD800...0xDBFF).contains(value) {
      guard match("\\") && match("u") else { throw ParserError.invalidUnicodeEscape }
      let lowHex = try readHexDigits(count: 4)
      guard let lowValue = UInt32(lowHex, radix: 16),
            (0xDC00...0xDFFF).contains(lowValue) else {
        throw ParserError.invalidUnicodeEscape
      }
      let combined = 0x10000 + ((value - 0xD800) << 10) + (lowValue - 0xDC00)
      guard let scalar = UnicodeScalar(combined) else { throw ParserError.invalidUnicodeEscape }
      return scalar
    }

    if (0xDC00...0xDFFF).contains(value) {
      throw ParserError.invalidUnicodeEscape
    }

    guard let scalar = UnicodeScalar(value) else { throw ParserError.invalidUnicodeEscape }
    return scalar
  }

  private mutating func readHexDigits(count: Int) throws -> String {
    var result = ""
    for _ in 0..<count {
      guard let character = advance(), character.isHexDigit else { throw ParserError.invalidUnicodeEscape }
      result.append(character)
    }
    return result
  }

  private mutating func parseNumberLiteral() throws -> String {
    let start = index

    if match("-") { }

    if match("0") {
      if let next = peek(), next.isWholeNumber {
        throw ParserError.invalidNumber
      }
    } else {
      try parseDigits(required: true)
    }

    if match(".") {
      try parseDigits(required: true)
    }

    if match("e") || match("E") {
      if match("+") == false {
        _ = match("-")
      }
      try parseDigits(required: true)
    }

    return String(text[start..<index])
  }

  private mutating func parseDigits(required: Bool) throws {
    var hasDigit = false
    while let character = peek(), character.isWholeNumber {
      _ = advance()
      hasDigit = true
    }
    if required && !hasDigit {
      throw ParserError.invalidNumber
    }
  }

  private mutating func expect(_ character: Character) throws {
    guard match(character) else { throw ParserError.invalidCharacter(peek() ?? character) }
  }

  private mutating func expectLiteral(_ literal: String) throws {
    for expected in literal {
      guard match(expected) else { throw ParserError.invalidCharacter(peek() ?? expected) }
    }
  }

  private mutating func match(_ character: Character) -> Bool {
    guard let current = peek(), current == character else { return false }
    _ = advance()
    return true
  }

  private mutating func advance() -> Character? {
    guard !isAtEnd else { return nil }
    let character = text[index]
    index = text.index(after: index)
    return character
  }

  private func peek() -> Character? {
    guard !isAtEnd else { return nil }
    return text[index]
  }

  private mutating func skipWhitespace() {
    while let character = peek(), character.isWhitespace {
      _ = advance()
    }
  }

  private var isAtEnd: Bool {
    index >= text.endIndex
  }
}
