import Foundation

private let log = SnapOLog.tracker

actor DeviceTracker {
  private let adbService: ADBService

  private var trackTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]
  private var latestDevices: [Device] = []
  private var infoCache: [String: DeviceInfo] = [:]

  init(adbService: ADBService) {
    self.adbService = adbService
  }

  // MARK: - Public API

  func deviceStream() -> AsyncStream<[Device]> {
    let id = UUID()
    return AsyncStream { continuation in
      continuations[id] = continuation
      continuation.yield(latestDevices)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(id) }
      }
      if trackTask == nil {
        startTracking()
      }
    }
  }

  // MARK: - Tracking

  private func startTracking() {
    trackTask?.cancel()
    trackTask = Task { [weak self] in
      await self?.trackLoop()
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations.removeValue(forKey: id)
    if continuations.isEmpty {
      trackTask?.cancel()
      trackTask = nil
    }
  }

  private func broadcast(_ devices: [Device]) {
    latestDevices = devices
    for continuation in continuations.values {
      continuation.yield(devices)
    }
  }

  private func trackLoop() async {
    while !Task.isCancelled {
      await adbService.awaitConfigured()
      guard let exec = try? await adbService.exec() else {
        broadcast([])
        try? await Task.sleep(for: .milliseconds(300))
        continue
      }
      guard let (processHandles, stream) = try? exec.trackDevices() else {
        broadcast([])
        try? await Task.sleep(for: .milliseconds(300))
        continue
      }

      for await payload in stream {
        if Task.isCancelled { break }
        let devices = await parseDevices(from: payload, exec: exec)
        broadcast(devices)
      }

      if processHandles.process.isRunning { processHandles.process.terminate() }
      _ = try? processHandles.stderr.fileHandleForReading.readToEnd()

      try? await Task.sleep(for: .milliseconds(300))
    }
  }

  // MARK: - Device parsing

  private func parseDevices(from payload: String, exec: ADBExec) async -> [Device] {
    let lines = payload.split(separator: "\n").dropFirst() // drop header
    var results: [Device] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.contains("offline") else { continue }

      let parts = trimmed.split(separator: " ")
      guard let serial = parts.first else { continue }
      let id = String(serial)

      var modelFromList: String?
      for part in parts where part.hasPrefix("model:") {
        modelFromList = String(part.dropFirst(6))
      }

      let info = await deviceInfo(for: id, fallbackModel: modelFromList, exec: exec)
      results.append(Device(
        id: id,
        model: info.model,
        androidVersion: info.version,
        vendorModel: info.vendorModel,
        manufacturer: info.manufacturer,
        avdName: info.avdName
      ))
    }

    return results
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
