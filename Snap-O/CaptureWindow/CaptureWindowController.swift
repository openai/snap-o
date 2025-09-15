import AppKit
import Combine
import Foundation

@MainActor
final class CaptureWindowController: ObservableObject {
  private let services: AppServices

  @Published private(set) var mediaList: [CaptureMedia] = []
  @Published private(set) var selectedMediaID: CaptureMedia.ID?
  @Published private(set) var transitionDirection: DeviceTransitionDirection = .neutral
  @Published private(set) var isDeviceListInitialized: Bool = false
  @Published private(set) var isProcessing: Bool = false
  @Published private(set) var isRecording: Bool = false
  @Published private(set) var lastError: String?

  private var knownDevices: [Device] = []
  private var recordingSessions: [String: RecordingSession] = [:]
  private var deviceStreamTask: Task<Void, Never>?

  init(services: AppServices = .shared) {
    self.services = services
  }

  deinit {
    deviceStreamTask?.cancel()
  }

  func start() async {
    deviceStreamTask?.cancel()
    let tracker = services.deviceTracker
    isDeviceListInitialized = tracker.latestDevices.isEmpty ? false : true

    deviceStreamTask = Task { [weak self] in
      guard let self else { return }
      for await devices in tracker.deviceStream() {
        await MainActor.run {
          self.handleDeviceUpdate(devices)
          if !self.isDeviceListInitialized { self.isDeviceListInitialized = true }
        }
      }
    }
  }

  func selectMedia(id: CaptureMedia.ID?, direction: DeviceTransitionDirection) {
    guard selectedMediaID != id else {
      transitionDirection = direction
      return
    }

    transitionDirection = direction
    Task { @MainActor [weak self] in
      await Task.yield()
      self?.selectedMediaID = id
    }
  }

  func selectNextMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id, direction: .down)
      return
    }
    let nextIndex = (currentIndex + 1) % mediaList.count
    selectMedia(id: mediaList[nextIndex].id, direction: .down)
  }

  func selectPreviousMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id, direction: .up)
      return
    }
    let previousIndex = (currentIndex - 1 + mediaList.count) % mediaList.count
    selectMedia(id: mediaList[previousIndex].id, direction: .up)
  }

  func hasAlternativeMedia() -> Bool {
    mediaList.count > 1
  }

  var hasDevices: Bool { !knownDevices.isEmpty }

  var currentCapture: CaptureMedia? {
    guard let id = selectedMediaID else { return mediaList.first }
    return mediaList.first { $0.id == id }
  }

  func captureScreenshots() async {
    let devices = knownDevices
    guard !devices.isEmpty else { return }

    isProcessing = true
    lastError = nil

    let captureService = services.captureService
    let (newMedia, encounteredError) = await collectMedia(for: devices) { device in
      try await captureService.captureScreenshot(for: device.id)
    }

    applyCaptureResults(newMedia: newMedia, encounteredError: encounteredError)
  }

  func startRecording() async {
    let devices = knownDevices
    guard !devices.isEmpty, !isRecording else { return }
    isProcessing = true
    lastError = nil

    let deviceIDs = devices.map { $0.id }
    var sessions: [String: RecordingSession] = [:]
    var encounteredError: Error?

    let captureService = services.captureService

    await withTaskGroup(of: (String, Result<RecordingSession, Error>).self) { group in
      for deviceID in deviceIDs {
        group.addTask {
          do {
            let session = try await captureService.startRecording(for: deviceID)
            return (deviceID, .success(session))
          } catch {
            return (deviceID, .failure(error))
          }
        }
      }

      for await (deviceID, result) in group {
        switch result {
        case .success(let session):
          sessions[deviceID] = session
        case .failure(let error):
          encounteredError = error
        }
      }
    }

    if let error = encounteredError {
      lastError = error.localizedDescription
      isProcessing = false
      return
    }

    recordingSessions = sessions
    isRecording = true
    isProcessing = false
  }

  func stopRecording() async {
    guard isRecording else { return }
    let devices = knownDevices
    guard !devices.isEmpty else {
      recordingSessions.removeAll()
      isRecording = false
      return
    }

    isProcessing = true
    lastError = nil

    let captureService = services.captureService
    let sessions = recordingSessions
    let (newMedia, encounteredError) = await collectMedia(for: devices) { device in
      guard let session = sessions[device.id] else { return nil }
      return try await captureService.stopRecording(session: session, deviceID: device.id)
    }

    applyCaptureResults(newMedia: newMedia, encounteredError: encounteredError)
    recordingSessions.removeAll()
    isRecording = false
  }

  func copyCurrentImage() {
    guard let capture = currentCapture,
          case .image(let url, _) = capture.media,
          let image = NSImage(contentsOf: url)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  func makeTempDragFile(kind: MediaSaveKind) -> URL? {
    guard let media = currentCapture?.media,
          let url = media.url,
          media.saveKind == kind
    else { return nil }

    do {
      let fileStore = services.fileStore
      let fileURL = fileStore.makeDragDestination(
        capturedAt: media.capturedAt,
        kind: kind
      )
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.copyItem(at: url, to: fileURL)
      }
      return fileURL
    } catch {
      return nil
    }
  }

  private func collectMedia(
    for devices: [Device],
    action: @Sendable @escaping (Device) async throws -> Media?
  ) async -> ([CaptureMedia], Error?) {
    var newMedia: [CaptureMedia] = []
    var encounteredError: Error?

    await withTaskGroup(of: (Device, Result<Media?, Error>).self) { group in
      for device in devices {
        group.addTask {
          do {
            return (device, .success(try await action(device)))
          } catch {
            return (device, .failure(error))
          }
        }
      }

      for await (device, result) in group {
        switch result {
        case .success(let media):
          if let media {
            newMedia.append(
              CaptureMedia(deviceID: device.id, device: device, media: media)
            )
          }
        case .failure(let error):
          encounteredError = error
        }
      }
    }

    return (newMedia, encounteredError)
  }

  private func applyCaptureResults(
    newMedia: [CaptureMedia],
    encounteredError: Error?
  ) {
    if let error = encounteredError {
      lastError = error.localizedDescription
    }

    if !newMedia.isEmpty {
      let previousDeviceID = selectedMediaID.flatMap { currentID in
        mediaList.first(where: { $0.id == currentID })?.deviceID
      }

      mediaList = newMedia.sorted { $0.device.displayTitle < $1.device.displayTitle }

      if let previousDeviceID,
         let preserved = mediaList.first(where: { $0.deviceID == previousDeviceID }) {
        selectedMediaID = preserved.id
      } else {
        selectedMediaID = mediaList.first?.id
      }

      transitionDirection = .neutral
    }

    isProcessing = false
  }

  private func handleDeviceUpdate(_ devices: [Device]) {
    knownDevices = devices
    if mediaList.isEmpty {
      selectedMediaID = nil
    }
  }

}
