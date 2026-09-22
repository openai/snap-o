import Foundation
import Observation

@Observable
@MainActor
final class DeviceFileDrop {
  struct Failure {
    let message: String
    let details: String?
  }

  enum ConflictChoice { case keepBoth, replace, skip, cancel }

  let device: Device
  var pendingFiles: [URL] = []
  var asksToInstall = false
  var conflictName = ""
  var asksAboutConflict = false
  var isBusy = false
  var status: String?
  var progress: Double?
  var failures: [Failure] = []
  @ObservationIgnored private let adb = ADBClient()
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var conflictReply: CheckedContinuation<ConflictChoice, Never>?

  init(device: Device) {
    self.device = device
  }

  var canAcceptDrop: Bool {
    !isBusy && !asksToInstall
  }

  var installPrompt: String {
    let apks = pendingFiles.filter { $0.pathExtension.lowercased() == "apk" }
    let name = apks.count == 1 ? "\(apks[0].lastPathComponent)" : "\(apks.count) APKs"
    return "Install \(name) on \(device.avdName ?? device.model)?"
  }

  var installMessage: String {
    let count = pendingFiles.count { $0.pathExtension.lowercased() != "apk" }
    return count == 0 ? "" : "\(count) other \(count == 1 ? "file will" : "files will") copy to Downloads."
  }

  @discardableResult
  func receive(_ urls: [URL]) -> Bool {
    guard canAcceptDrop, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
    dismiss()
    var seen: Set<URL> = []
    pendingFiles = urls.filter { seen.insert($0).inserted }
    asksToInstall = pendingFiles.contains { $0.pathExtension.lowercased() == "apk" }
    if !asksToInstall { start(install: false) }
    return true
  }

  func start(install: Bool) {
    asksToInstall = false
    let files = pendingFiles
    pendingFiles = []
    guard !files.isEmpty else { return }
    isBusy = true
    work = Task { await transfer(files, install: install) }
  }

  func answerConflict(_ choice: ConflictChoice) {
    let reply = conflictReply
    conflictReply = nil
    asksAboutConflict = false
    reply?.resume(returning: choice)
  }

  func cancel() {
    work?.cancel()
    answerConflict(.cancel)
    asksToInstall = false
    pendingFiles = []
  }

  func dismiss() {
    status = nil
    failures = []
  }

  private func transfer(_ files: [URL], install: Bool) async {
    var copied = 0
    var installed = 0
    var skipped = 0
    var cancelled = false
    defer {
      isBusy = false
      progress = nil
      var results: [String] = []
      if copied > 0 { results.append("\(copied) copied to Downloads") }
      if installed > 0 { results.append("\(installed) installed") }
      if skipped > 0 { results.append("\(skipped) skipped") }
      if cancelled { results.append("Cancelled") }
      status = results.isEmpty ? nil : results.joined(separator: " · ")
    }
    var directory: String?
    for url in files {
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      do {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw ADBError.protocolFailure("Only regular files are supported.")
        }
        let size = Int64(values.fileSize ?? 0)
        let isAPK = install && url.pathExtension.lowercased() == "apk"
        status = "\(isAPK ? "Installing" : "Copying") \(url.lastPathComponent)…"
        progress = 0
        let update: @Sendable (Int64) -> Void = { [weak self] sent in
          Task { @MainActor in
            self?.progress = size > 0 && sent < size ? Double(sent) / Double(size) : nil
          }
        }
        if isAPK {
          try await adb.installAPK(deviceID: device.id, localURL: url, progress: update)
          installed += 1
        } else {
          if directory == nil { directory = try await adb.downloadsDirectory(deviceID: device.id) }
          guard let directory else { continue }
          let name = try DeviceFileCommand.filename(url.lastPathComponent)
          guard let destination = try await resolveDestination(name: name, directory: directory) else {
            skipped += 1
            continue
          }
          let warning = try await adb.copyFile(
            deviceID: device.id, localURL: url, destination: destination.path, replace: destination.replace, progress: update
          )
          copied += 1
          if let warning {
            failures.append(Failure(message: "Copied; media indexing failed", details: "\(name): \(warning)"))
          }
        }
      } catch {
        if Task.isCancelled || error is CancellationError {
          cancelled = true
          break
        }
        let blocked = error is DeviceFileTransferError
        failures.append(Failure(
          message: blocked ? "File transfers blocked by device policy" : "Couldn’t transfer \(url.lastPathComponent)",
          details: blocked ? nil : "\(url.lastPathComponent): \(error.localizedDescription)"
        ))
      }
    }
  }

  private func resolveDestination(name: String, directory: String) async throws -> (path: String, replace: Bool)? {
    let path = "\(directory)/\(name)"
    guard try await adb.fileExists(deviceID: device.id, path: path) else { return (path, false) }
    try Task.checkCancellation()
    let choice = await withCheckedContinuation { continuation in
      conflictReply = continuation
      conflictName = name
      asksAboutConflict = true
    }
    try Task.checkCancellation()
    switch choice {
    case .skip: return nil
    case .cancel: throw CancellationError()
    case .replace: return (path, true)
    case .keepBoth:
      var copy = 1
      var candidate: String
      repeat {
        candidate = try "\(directory)/\(DeviceFileCommand.filename(name, copy: copy))"
        copy += 1
      } while try await adb.fileExists(deviceID: device.id, path: candidate)
      return (candidate, false)
    }
  }
}
