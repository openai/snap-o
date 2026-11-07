import Foundation

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
  ) async throws {
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
