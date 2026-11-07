import Foundation

enum DeviceFileCommand {
  static func blocksFileTransfers(_ output: String, user: Int) -> Bool {
    var matchesUser = false
    var restrictionsIndent: Int?
    for line in output.components(separatedBy: .newlines) {
      let text = line.trimmingCharacters(in: .whitespaces)
      let indentation = line.prefix { $0.isWhitespace }
      let indent = indentation.count
      if text.hasPrefix("UserInfo{") {
        matchesUser = text.hasPrefix("UserInfo{\(user):")
        restrictionsIndent = nil
      }
      guard matchesUser else { continue }
      if text == "Effective restrictions:" {
        restrictionsIndent = indent
      } else if let sectionIndent = restrictionsIndent, !text.isEmpty {
        if indent <= sectionIndent {
          restrictionsIndent = nil
        } else if text == "no_usb_file_transfer" {
          return true
        }
      }
    }
    return false
  }

  static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func checked(_ command: String) -> String {
    "\(command) 2>&1; printf '\\nSNAPO_FILE_EXIT:%s\\n' \"$?\""
  }

  static func result(_ output: String) throws -> String {
    var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
      lines.removeLast()
    }
    guard let last = lines.popLast(), last.hasPrefix("SNAPO_FILE_EXIT:"),
          let status = Int32(last.dropFirst("SNAPO_FILE_EXIT:".count).trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw ADBError.parseFailure("The device did not return a file operation result.") }
    let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard status == 0 else { throw ADBError.nonZeroExit(status, stderr: message) }
    return message
  }

  static func filename(_ name: String, copy: Int = 0) throws -> String {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
          !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw ADBError.protocolFailure("This filename is not supported.") }
    guard copy > 0 else { return name }
    let url = URL(fileURLWithPath: name)
    let suffix = url.pathExtension
    return suffix.isEmpty ? "\(name) (\(copy))" : "\(url.deletingPathExtension().lastPathComponent) (\(copy)).\(suffix)"
  }
}

enum DeviceFileTransferError: LocalizedError {
  case blockedByPolicy

  var errorDescription: String? {
    "File transfers are blocked by device policy."
  }
}
