import Foundation

private let log = SnapOLog.tracker

actor DeviceTracker {
  private let adbClient: ADBClient

  private var trackTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<[Device]>.Continuation] = [:]
  private var latestDevices: [Device] = []
  private var infoCache: [String: DeviceInfo] = [:]

  init(adbURL: URL?) {
    adbClient = ADBClient(adbURL: adbURL)
  }

  init(adbClient: ADBClient) {
    self.adbClient = adbClient
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
    var backoff: TimeInterval = 0.5
    let maxBackoff: TimeInterval = 5

    while !Task.isCancelled {
      await adbClient.awaitConfigured()
      guard let adbURL = await adbClient.currentURL() else { continue }
      let allowed = adbURL.startAccessingSecurityScopedResource()
      defer { if allowed { adbURL.stopAccessingSecurityScopedResource() } }

      if !FileManager.default.fileExists(atPath: adbURL.path) {
        broadcast([])
        try? await Task.sleep(for: .seconds(backoff))
        backoff = min(backoff * 2, maxBackoff)
        continue
      }
      backoff = 0.5

      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = adbURL
      process.arguments = ["track-devices", "-l"]
      process.standardOutput = stdout
      process.standardError = stderr

      do {
        log.debug("Run adb \(adbURL.path, privacy: .public) track-devices -l")
        try process.run()
      } catch {
        broadcast([])
        try? await Task.sleep(for: .seconds(backoff))
        backoff = min(backoff * 2, maxBackoff)
        continue
      }

      var parser = TrackParser()
      var buffer = Data()

      let stream = AsyncStream<Data> { continuation in
        stdout.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if data.isEmpty {
            handle.readabilityHandler = nil
            continuation.finish()
          } else {
            continuation.yield(data)
          }
        }
        continuation.onTermination = { _ in
          stdout.fileHandleForReading.readabilityHandler = nil
        }
      }

      readLoop: for await chunk in stream {
        if Task.isCancelled { break readLoop }
        buffer.append(chunk)
        let payloads = parser.drain(&buffer)
        for payload in payloads {
          let devices = await parseDevices(from: payload)
          broadcast(devices)
        }
      }

      if process.isRunning { process.terminate() }
      _ = try? stderr.fileHandleForReading.readToEnd()

      try? await Task.sleep(for: .milliseconds(300))
    }
  }

  // MARK: - Device parsing

  private func parseDevices(from payload: String) async -> [Device] {
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

      let info = await deviceInfo(for: id, fallbackModel: modelFromList)
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

  private func deviceInfo(for id: String, fallbackModel: String?) async -> DeviceInfo {
    if let cached = infoCache[id] {
      return cached
    }

    async let modelTask: String = {
      if let model = fallbackModel { return model }
      return await (try? adbClient.getProp(deviceID: id, key: "ro.product.model")) ?? "Unknown Model"
    }()

    async let versionTask: String = await (try? adbClient.getProp(deviceID: id, key: "ro.build.version.release")) ?? "Unknown API"

    // Prefer vendor model/manufacturer when available, with sensible fallbacks.
    async let vendorModelTask: String? = {
      let v = await (try? adbClient.getProp(deviceID: id, key: "ro.product.vendor.model"))
      let trimmed = v?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (trimmed?.isEmpty == false) ? trimmed : nil
    }()
    async let manufacturerTask: String? = {
      // Prefer vendor.manufacturer, fall back to product.manufacturer.
      let vendor = await (try? adbClient.getProp(deviceID: id, key: "ro.product.vendor.manufacturer"))?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let vendor, !vendor.isEmpty { return vendor }
      let prod = await (try? adbClient.getProp(deviceID: id, key: "ro.product.manufacturer"))?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (prod?.isEmpty == false) ? prod : nil
    }()

    // Emulator AVD name (underscores replaced with spaces)
    async let avdNameTask: String? = {
      let raw = await (try? adbClient.getProp(deviceID: id, key: "ro.boot.qemu.avd_name"))?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let raw, !raw.isEmpty else { return nil }
      return raw.replacingOccurrences(of: "_", with: " ")
    }()

    let info = await DeviceInfo(
      model: modelTask,
      version: versionTask,
      vendorModel: vendorModelTask,
      manufacturer: manufacturerTask,
      avdName: avdNameTask
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

  /// Parses the output stream from `adb track-devices -l`. The stream begins
  /// with hex-length-prefixed payloads but can fall back to CRLF separated
  /// blocks depending on the adb server version. This parser understands both
  /// formats and surfaces complete payload strings.
  private struct TrackParser {
    enum Mode { case lengthPrefixed, lineDelimited }

    private var mode: Mode = .lengthPrefixed
    private var expectedLength: Int?

    private let lf2 = Data([0x0A, 0x0A])
    private let crlf2 = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private let maxBuffer = 1 << 20 // 1MB safety cap

    mutating func drain(_ buffer: inout Data) -> [String] {
      var payloads: [String] = []

      parseLoop: while true {
        switch mode {
        case .lengthPrefixed:
          if expectedLength == nil {
            guard buffer.count >= 4 else { break parseLoop }
            let prefix = buffer.prefix(4)
            guard let hex = String(data: prefix, encoding: .ascii), let len = Int(hex, radix: 16) else {
              mode = .lineDelimited
              expectedLength = nil
              continue parseLoop
            }
            expectedLength = len
            buffer.removeFirst(4)
          }

          guard let length = expectedLength, buffer.count >= length else { break parseLoop }
          let payload = buffer.prefix(length)
          buffer.removeFirst(length)
          expectedLength = nil
          if let string = String(data: payload, encoding: .utf8) {
            payloads.append("List of devices attached\n" + string + "\n")
          }

        case .lineDelimited:
          let lfRange = buffer.range(of: lf2)
          let crlfRange = buffer.range(of: crlf2)
          let separatorRange: Range<Data.Index>? = switch (lfRange, crlfRange) {
          case (let lf?, let crlf?): lf.lowerBound < crlf.lowerBound ? lf : crlf
          case (let lf?, nil): lf
          case (nil, let crlf?): crlf
          default: nil
          }
          guard let range = separatorRange else { break parseLoop }
          let block = buffer.subdata(in: buffer.startIndex ..< range.lowerBound)
          buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
          if let string = String(data: block, encoding: .utf8), !string.isEmpty {
            payloads.append("List of devices attached\n" + string + "\n")
          }
        }

        if buffer.count > maxBuffer {
          buffer.removeAll(keepingCapacity: true)
        }
      }

      return payloads
    }
  }
}
