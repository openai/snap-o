import Foundation

private let log = SnapOLog.tracker

final class DeviceTracker: @unchecked Sendable {
  private let adbService: ADBService

  private var trackTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]
  private let lock = NSLock()
  private var _latestDevices: [Device] = []
  var latestDevices: [Device] {
    lock.lock()
    defer { lock.unlock() }
    return _latestDevices
  }

  private var infoCache: [String: DeviceInfo] = [:]
  private var hasSeenFirstMessage: Bool = false

  init(adbService: ADBService) {
    self.adbService = adbService
  }

  // MARK: - Public API

  func deviceStream() -> AsyncStream<[Device]> {
    let id = UUID()
    return AsyncStream { continuation in
      lock.lock()
      continuations[id] = continuation
      lock.unlock()
      if self.hasSeenFirstMessage {
        continuation.yield(self.latestDevices)
      }

      continuation.onTermination = { [weak self] _ in
        self?.removeContinuation(id)
      }
    }
  }

  // MARK: - Tracking

  func startTracking() {
    trackTask?.cancel()
    trackTask = Task { [weak self] in
      await self?.trackLoop()
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations.removeValue(forKey: id)
  }

  private func broadcast(_ devices: [Device]) {
    lock.lock()
    _latestDevices = devices
    hasSeenFirstMessage = true
    let snapshot = Array(continuations.values)
    lock.unlock()
    for continuation in snapshot {
      continuation.yield(devices)
    }
  }

  private func trackLoop() async {
    @inline(__always)
    func pause() async {
      try? await Task.sleep(for: .milliseconds(300))
    }

    while !Task.isCancelled {
      let exec = await adbService.exec()
      guard let (handle, stream) = try? await exec.trackDevices() else {
        if hasSeenFirstMessage { broadcast([]) }
        await pause()
        continue
      }

      defer { handle.cancel() }

      do {
        for try await payload in stream {
          if Task.isCancelled { break }
          let devices = await parseDevices(from: payload, exec: exec)
          broadcast(devices)
        }
        await pause()
      } catch is CancellationError {
        break
      } catch {
        if hasSeenFirstMessage { broadcast([]) }
        await pause()
      }
    }
  }

  // MARK: - Device parsing

  private func parseDevices(from payload: String, exec: ADBExec) async -> [Device] {
    let parsed = payload
      .split(separator: "\n", omittingEmptySubsequences: true)
      .compactMap(parseDeviceRow)

    return await withTaskGroup(of: Device?.self) { group in
      for (id, fields) in parsed {
        group.addTask {
          let info = await self.deviceInfo(for: id, fallbackModel: fields["model"], exec: exec)
          return Device(
            id: id,
            model: info.model,
            androidVersion: info.version,
            vendorModel: info.vendorModel,
            manufacturer: info.manufacturer,
            avdName: info.avdName
          )
        }
      }
      var out: [Device] = []
      for await device in group {
        if let device { out.append(device) }
      }
      return out
    }
  }

  /// Parses a single `adb devices -l` row like:
  ///   `<serial> device product:foo model:Pixel_7 device:panther transport_id:3`
  /// Returns nil for headers, empties, or unwanted states (offline/unauthorized).
  private func parseDeviceRow(_ line: Substring) -> (id: String, fields: [String: String])? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(whereSeparator: \.isWhitespace)
    guard let first = parts.first else { return nil }
    let id = String(first)

    if parts.count >= 2 {
      let state = parts[1].lowercased()
      if state.contains("offline") || state.contains("unauthorized") || state.contains("recovery") {
        return nil
      }
    }

    // Parse key:value pairs into a dictionary.
    var fields: [String: String] = [:]
    fields.reserveCapacity(6)
    for part in parts.dropFirst() {
      if let idx = part.firstIndex(of: ":") {
        let key = String(part[..<idx])
        let value = String(part[part.index(after: idx)...])
        fields[key] = value
      }
    }

    return (id, fields)
  }

  private func deviceInfo(for id: String, fallbackModel: String?, exec: ADBExec) async -> DeviceInfo {
    if let cached = infoCache[id] {
      return cached
    }

    // Single getprop dump and extract the properties we care about
    let props = await (try? exec.getProperties(deviceID: id, prefix: "ro.")) ?? [:]

    let model = fallbackModel
      ?? cleanProp("ro.product.model", in: props)
      ?? "Unknown Model"
    let version = cleanProp("ro.build.version.release", in: props) ?? "Unknown API"
    let vendorModel = cleanProp("ro.product.vendor.model", in: props)
    let manufacturer = cleanProp("ro.product.vendor.manufacturer", in: props)
      ?? cleanProp("ro.product.manufacturer", in: props)
    let avdName = cleanProp("ro.boot.qemu.avd_name", in: props)
      .map { $0.replacingOccurrences(of: "_", with: " ") }

    let info = DeviceInfo(
      model: model,
      version: version,
      vendorModel: vendorModel,
      manufacturer: manufacturer,
      avdName: avdName
    )
    infoCache[id] = info
    return info
  }

  // MARK: - Helpers

  private struct DeviceInfo {
    let model: String
    let version: String
    let vendorModel: String?
    let manufacturer: String?
    let avdName: String?
  }

  // MARK: - Property helpers

  private func cleanProp(_ key: String, in props: [String: String]) -> String? {
    guard let raw = props[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return raw.isEmpty ? nil : raw
  }
}
