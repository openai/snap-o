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

extension ADBClient {
  func fileCommand(deviceID: String, command: String, timeout: Duration = .seconds(30)) async throws -> String {
    let output = try await withConnection(maxAttempts: 1) { connection in
      try connection.withRequestTimeout(timeout) {
        try connection.sendTransport(to: deviceID)
        try connection.sendShell(DeviceFileCommand.checked(command))
        guard let output = try String(bytes: connection.readToEnd(), encoding: .utf8) else {
          throw ADBError.parseFailure("The device returned invalid text.")
        }
        return output
      }
    }
    return try DeviceFileCommand.result(output)
  }

  func downloadsDirectory(deviceID: String) async throws -> String {
    let output = try await fileCommand(deviceID: deviceID, command: "am get-current-user")
    guard let user = Int(output), user >= 0 else { throw ADBError.parseFailure("The Android user is unavailable.") }
    // Android's shared-storage layer can report this policy denial as EFAULT ("Bad address").
    if let restrictions = try? await fileCommand(deviceID: deviceID, command: "dumpsys user"),
       DeviceFileCommand.blocksFileTransfers(restrictions, user: user) {
      throw DeviceFileTransferError.blockedByPolicy
    }
    // /sdcard points at user 0 for ADB, even when another user is in the foreground.
    let path = "/storage/emulated/\(user)/Download"
    _ = try await fileCommand(deviceID: deviceID, command: "mkdir -p \(DeviceFileCommand.quote(path))")
    return path
  }

  func fileExists(deviceID: String, path: String) async throws -> Bool {
    let path = DeviceFileCommand.quote(path)
    return try await fileCommand(
      deviceID: deviceID, command: "if [ -e \(path) ] || [ -L \(path) ]; then echo yes; else echo no; fi"
    ) == "yes"
  }

  func uploadFile(
    deviceID: String, localURL: URL, remotePath: String,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    try await withConnection(maxAttempts: 1) { connection in
      try connection.withRequestTimeout(.seconds(30)) {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        try connection.sendTransport(to: deviceID)
        try connection.sendSync()
        try connection.sendFile(file, remotePath: remotePath, progress: progress)
      }
    }
  }

  func copyFile(
    deviceID: String, localURL: URL, destination: String, replace: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String? {
    let directory = (destination as NSString).deletingLastPathComponent
    let staging = "\(directory)/.snap-o-\(UUID().uuidString).partial"
    do {
      try await uploadFile(deviceID: deviceID, localURL: localURL, remotePath: staging, progress: progress)
      let source = DeviceFileCommand.quote(staging)
      let target = DeviceFileCommand.quote(destination)
      // A no-clobber move also protects files created after the conflict prompt.
      _ = try await fileCommand(
        deviceID: deviceID,
        command: "(if [ -d \(target) ]; then echo 'A folder already uses this name.'; exit 1; fi; "
          + "mv \(replace ? "-f" : "-n") \(source) \(target) || exit $?; "
          + "if [ -e \(source) ]; then echo 'Another file now uses this name. Drop the file again.'; exit 1; fi)"
      )
    } catch {
      await removeTransferFile(deviceID: deviceID, path: staging)
      throw error
    }
    let mediaExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "mp4", "mov", "mkv", "webm", "mp3", "wav"]
    if mediaExtensions.contains(localURL.pathExtension.lowercased()) {
      do {
        let uri = URL(fileURLWithPath: destination).absoluteString
        _ = try await fileCommand(
          deviceID: deviceID,
          command: "am broadcast --user current -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(DeviceFileCommand.quote(uri))"
        )
      } catch {
        return "Copied, but media indexing failed: \(error.localizedDescription)"
      }
    }
    return nil
  }

  func installAPK(
    deviceID: String, localURL: URL, progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> Int {
    let staging = "/data/local/tmp/snap-o-\(UUID().uuidString).apk"
    do {
      let userOutput = try await fileCommand(deviceID: deviceID, command: "am get-current-user")
      guard let user = Int(userOutput), user >= 0 else { throw ADBError.parseFailure("The Android user is unavailable.") }
      try await uploadFile(deviceID: deviceID, localURL: localURL, remotePath: staging, progress: progress)
      let output = try await fileCommand(
        deviceID: deviceID,
        command: "pm install -r --user \(user) \(DeviceFileCommand.quote(staging))", timeout: .seconds(180)
      )
      guard output.split(whereSeparator: \.isNewline).contains("Success") else {
        throw ADBError.protocolFailure(output.isEmpty ? "Installation did not report success." : output)
      }
      await removeTransferFile(deviceID: deviceID, path: staging)
      return user
    } catch {
      await removeTransferFile(deviceID: deviceID, path: staging)
      throw error
    }
  }

  private func removeTransferFile(deviceID: String, path: String) async {
    // Cleanup needs its own task because the transfer may already be cancelled.
    await Task.detached {
      _ = try? await fileCommand(deviceID: deviceID, command: "rm -f \(DeviceFileCommand.quote(path))", timeout: .seconds(5))
    }.value
  }
}

enum DeviceFileTransferError: LocalizedError {
  case blockedByPolicy

  var errorDescription: String? {
    "File transfers are blocked by device policy."
  }
}
