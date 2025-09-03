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

    // Kick off concurrent lookups
    async let modelRaw: String? = try? await exec.getProp(deviceID: id, key: "ro.product.model")
    async let versionRaw: String? = try? await exec.getProp(deviceID: id, key: "ro.build.version.release")
    async let vendorModelRaw: String? = try? await exec.getProp(deviceID: id, key: "ro.product.vendor.model")
    async let vendorManufacturerRaw: String? = try? await exec.getProp(deviceID: id, key: "ro.product.vendor.manufacturer")
    async let productManufacturerRaw: String? = try? await exec.getProp(deviceID: id, key: "ro.product.manufacturer")
    async let avdNameRaw: String? = try? await exec.getProp(deviceID: id, key: "ro.boot.qemu.avd_name")

    // Resolve values with fallbacks
    let modelRawVal = await modelRaw
    let versionRawVal = await versionRaw
    let vendorModelRawVal = await vendorModelRaw
    let vendorManufacturerRawVal = await vendorManufacturerRaw
    let productManufacturerRawVal = await productManufacturerRaw
    let avdNameRawVal = await avdNameRaw

    let modelValue: String = {
      if let m = fallbackModel { return m }
      let trimmed = modelRawVal?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed ?? "Unknown Model"
    }()

    let versionValue: String = versionRawVal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown API"

    let vendorModelValue: String? = {
      let trimmed = vendorModelRawVal?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (trimmed?.isEmpty == false) ? trimmed : nil
    }()

    let manufacturerValue: String? = {
      let vendor = vendorManufacturerRawVal?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let vendor, !vendor.isEmpty { return vendor }
      let prod = productManufacturerRawVal?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (prod?.isEmpty == false) ? prod : nil
    }()

    let avdNameValue: String? = {
      let raw = avdNameRawVal?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let raw, !raw.isEmpty else { return nil }
      return raw.replacingOccurrences(of: "_", with: " ")
    }()

    let info = DeviceInfo(
      model: modelValue,
      version: versionValue,
      vendorModel: vendorModelValue,
      manufacturer: manufacturerValue,
      avdName: avdNameValue
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
}
