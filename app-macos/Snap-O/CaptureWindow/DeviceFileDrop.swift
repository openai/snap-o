import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class DeviceFileDrop {
  struct Conflict: Identifiable {
    let id = UUID()
    let name: String
  }

  struct InstalledApp: Identifiable {
    var id: String {
      packageName
    }

    let packageName: String
    let filename: String
    let user: Int
  }

  enum ConflictChoice { case keepBoth, replace, skip, cancel }

  let device: Device
  var pendingFiles: [URL] = []
  var asksToInstall = false
  var conflict: Conflict?
  var asksAboutConflict = false
  var isBusy = false
  var status: String?
  var progress: Double?
  var failures: [String] = []
  var failureSummary: String?
  var hasFailureDetails = false
  var installedApps: [InstalledApp] = []
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

  func receive(_ providers: [NSItemProvider]) -> Bool {
    guard canAcceptDrop, !providers.isEmpty else { return false }
    isBusy = true
    failures = []
    failureSummary = nil
    hasFailureDetails = false
    installedApps = []
    status = nil
    work = Task {
      var urls: [URL] = []
      for provider in providers {
        do {
          let url: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, error in
              if let url = object as? URL, url.isFileURL {
                continuation.resume(returning: url)
              } else {
                continuation.resume(throwing: error ?? CocoaError(.fileReadUnsupportedScheme))
              }
            }
          }
          try Task.checkCancellation()
          if !urls.contains(url) { urls.append(url) }
        } catch {
          if Task.isCancelled { break }
          failures.append(error.localizedDescription)
          hasFailureDetails = true
        }
      }
      isBusy = false
      guard !Task.isCancelled else { return }
      pendingFiles = urls
      if urls.contains(where: { $0.pathExtension.lowercased() == "apk" }) {
        asksToInstall = true
      } else {
        start(install: false)
      }
    }
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
    conflict = nil
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
    failureSummary = nil
    hasFailureDetails = false
    installedApps = []
  }

  func open(_ app: InstalledApp) {
    work = Task {
      isBusy = true
      defer { isBusy = false }
      do {
        try await adb.openApp(deviceID: device.id, packageName: app.packageName, androidUserID: app.user)
      } catch {
        failureSummary = "Couldn’t open app"
        hasFailureDetails = true
        failures.append(error.localizedDescription)
      }
    }
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
          let package = await Task.detached { try? APKPackageName.read(from: url) }.value
          let user = try await adb.installAPK(deviceID: device.id, localURL: url, progress: update)
          installed += 1
          if let package {
            installedApps.removeAll { $0.packageName == package }
            installedApps.append(InstalledApp(packageName: package, filename: url.lastPathComponent, user: user))
          }
        } else {
          if directory == nil { directory = try await adb.downloadsDirectory(deviceID: device.id) }
          guard let directory else { continue }
          let name = try DeviceFileCommand.filename(url.lastPathComponent)
          var destination = "\(directory)/\(name)"
          var replace = false
          if try await adb.fileExists(deviceID: device.id, path: destination) {
            try Task.checkCancellation()
            let choice = await withCheckedContinuation { continuation in
              conflictReply = continuation
              conflict = Conflict(name: name)
              asksAboutConflict = true
            }
            try Task.checkCancellation()
            switch choice {
            case .skip:
              skipped += 1
              continue
            case .cancel: throw CancellationError()
            case .replace: replace = true
            case .keepBoth:
              var copy = 1
              repeat {
                destination = try "\(directory)/\(DeviceFileCommand.filename(name, copy: copy))"
                copy += 1
              } while try await adb.fileExists(deviceID: device.id, path: destination)
            }
          }
          let warning = try await adb.copyFile(
            deviceID: device.id, localURL: url, destination: destination, replace: replace, progress: update
          )
          copied += 1
          if let warning {
            failureSummary = "Copied; media indexing failed"
            hasFailureDetails = true
            failures.append("\(name): \(warning)")
          }
        }
      } catch {
        if Task.isCancelled || error is CancellationError {
          cancelled = true
          break
        }
        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
        if error is DeviceFileTransferError {
          failureSummary = "File transfers blocked by device policy"
        } else {
          hasFailureDetails = true
          failureSummary = failures.count == 1 ? "Couldn’t transfer \(url.lastPathComponent)" : "\(failures.count) transfers failed"
        }
      }
    }
  }
}

struct DeviceFileDropDelegate: DropDelegate {
  let model: DeviceFileDrop

  func validateDrop(info: DropInfo) -> Bool {
    model.canAcceptDrop && info.hasItemsConforming(to: [.fileURL])
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: model.canAcceptDrop ? .copy : .forbidden)
  }

  func performDrop(info: DropInfo) -> Bool {
    model.receive(info.itemProviders(for: [.fileURL]))
  }
}

struct DeviceFileDropStatus: View {
  @Bindable var model: DeviceFileDrop
  @State private var showsDetails = false

  private var message: String {
    if model.isBusy { return model.status ?? "Preparing…" }
    if !model.failures.isEmpty { return model.failureSummary ?? "Transfer failed" }
    return model.status ?? ""
  }

  var body: some View {
    HStack(spacing: 10) {
      if model.isBusy {
        ProgressView()
          .controlSize(.small)
          .frame(width: 14, height: 14)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(message)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if model.isBusy, let progress = model.progress {
          ProgressView(value: progress)
            .progressViewStyle(.linear)
        }
      }
      if model.isBusy {
        Button("Cancel", action: model.cancel)
          .fixedSize()
      } else {
        if !model.failures.isEmpty, model.hasFailureDetails || model.status != nil {
          Button("Details") { showsDetails = true }
            .fixedSize()
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
              ScrollView {
                Text(([model.status].compactMap(\.self) + model.failures).joined(separator: "\n\n"))
                  .font(.callout)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(16)
              }
              .frame(width: 340, height: 180)
            }
        } else if model.installedApps.count == 1, let app = model.installedApps.first {
          Button("Open app") { model.open(app) }
            .fixedSize()
        } else if !model.installedApps.isEmpty {
          Menu("Open app") {
            ForEach(model.installedApps) { app in
              Button(app.filename) { model.open(app) }
            }
          }
          .fixedSize()
        }
        Button(action: model.dismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Dismiss")
      }
    }
    .font(.callout)
    .controlSize(.small)
    .buttonStyle(.borderless)
    .padding(.vertical, 10)
    .padding(.leading, 14)
    .padding(.trailing, 10)
    .frame(maxWidth: 420)
    .fixedSize(horizontal: false, vertical: true)
    // Use a stable surface instead of glass's adaptive contrast over live video.
    .background(
      Color(nsColor: .windowBackgroundColor).opacity(0.92),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .padding(12)
    .task(id: model.status) {
      guard !model.isBusy, model.failures.isEmpty, model.installedApps.isEmpty, let status = model.status else { return }
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      if !model.isBusy, model.status == status, model.failures.isEmpty { model.dismiss() }
    }
  }
}
