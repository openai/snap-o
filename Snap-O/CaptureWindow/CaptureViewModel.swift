import AppKit
@preconcurrency import AVKit
import Observation

private let log = SnapOLog.ui

@MainActor
@Observable
final class CaptureViewModel {
  var currentMedia: Media?
  var isLoading = false
  var isRecording = false
  var recordingDeviceID: String?
  var recordingHandle: RecordingHandle?
  var lastError: String?
  var pendingCommand: SnapOCommand?
  var isLivePreviewing = false
  var livePreviewDeviceID: String?
  var livePreviewMedia: Media?
  @ObservationIgnored var livePreviewSampleBufferHandler: (@MainActor (CMSampleBuffer) -> Void)?

  @ObservationIgnored private var livePreviewTask: Task<Void, Never>?
  @ObservationIgnored private var livePreviewSession: ScreenStreamSession?
  @ObservationIgnored private var livePreviewDecoder: H264StreamDecoder?

  private let adb: ADBClient
  private let store: FileStore
  private let recordingService: RecordingService

  init(adb: ADBClient, store: FileStore, recordingService: RecordingService) {
    self.adb = adb
    self.store = store
    self.recordingService = recordingService
  }

  // MARK: - Convenience State

  var canCapture: Bool { !isLoading && !isRecording }
  var canStartRecording: Bool { !isLoading && !isRecording }
  var canStopRecording: Bool { isRecording }
  var canStartLivePreview: Bool { !isLoading && !isRecording && !isLivePreviewing }
  var canStopLivePreview: Bool { isLivePreviewing }
  var displayMedia: Media? { isLivePreviewing ? livePreviewMedia : currentMedia }

  func copy() {
    guard let media = currentMedia, media.kind == .image else { return }
    guard let image = NSImage(contentsOf: media.url) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  // Screenshot
  func refreshPreview(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    if isLivePreviewing {
      stopLivePreview()
    }
    currentMedia = nil
    if pendingCommand == .record {
      pendingCommand = nil
      await startRecording(for: deviceID)
      return
    }
    if pendingCommand == .livepreview {
      pendingCommand = nil
      await startLivePreview(for: deviceID)
      return
    }
    pendingCommand = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let data = try await adb.screencapPNG(deviceID: deviceID)
      let capturedAt = Date()
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: MediaKind.image)

      async let writeAndSize: (Int, Int) = Task.detached(priority: .utility) {
        try data.write(to: dest, options: [.atomic])
        return try pngSize(from: data)
      }.value
      async let densityTask = adb.screenDensityScale(deviceID: deviceID)

      let size = try await writeAndSize
      let density: CGFloat?
      do {
        density = try await densityTask
      } catch {
        density = nil
      }

      currentMedia = Media(
        kind: .image,
        url: dest,
        capturedAt: capturedAt,
        width: CGFloat(size.0),
        height: CGFloat(size.1),
        densityScale: density
      )
      lastError = nil
    } catch {
      currentMedia = nil
      lastError = error.localizedDescription
    }
  }

  func makeTempDragFile() -> URL? {
    guard let media = currentMedia else { return nil }

    do {
      let url = store.makeDragDestination(capturedAt: media.capturedAt, kind: media.kind)
      try FileManager.default.copyItem(at: media.url, to: url)
      return url
    } catch {
      log.error("Drag temp copy failed: \(error.localizedDescription)")
      return nil
    }
  }

  // Recording
  func startRecording(for deviceID: String) async {
    guard !isLoading, !isRecording else { return }
    if isLivePreviewing {
      stopLivePreview()
    }
    currentMedia = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let handle = try await recordingService.start(deviceID: deviceID)
      isRecording = true
      recordingDeviceID = deviceID
      recordingHandle = handle
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func stopRecording() async {
    guard isRecording, let deviceID = recordingDeviceID, let handle = recordingHandle else { return }
    isRecording = false
    recordingDeviceID = nil
    recordingHandle = nil
    isLoading = true
    defer { isLoading = false }
    do {
      let dest = store.makePreviewDestination(deviceID: deviceID, kind: MediaKind.video)
      try await recordingService.stop(handle: handle, savingTo: dest)
      let asset = AVURLAsset(url: dest)

      async let tracksTask = asset.load(.tracks)
      async let densityTask = adb.screenDensityScale(deviceID: deviceID)

      let tracks = try await tracksTask
      if let videoTrack = tracks.first(where: { $0.mediaType == .video }) {
        async let naturalSizeTask = videoTrack.load(.naturalSize)
        async let transformTask = videoTrack.load(.preferredTransform)
        let (naturalSize, transform) = try await (naturalSizeTask, transformTask)
        let applied = naturalSize.applying(transform)
        let w = abs(applied.width)
        let h = abs(applied.height)

        let density: CGFloat?
        do {
          density = try await densityTask
        } catch {
          density = nil
        }

        currentMedia = Media(
          kind: .video,
          url: dest,
          capturedAt: Date(),
          width: w,
          height: h,
          densityScale: density
        )
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  // Live Preview
  func startLivePreview(for deviceID: String) async {
    guard !isLoading, !isRecording, !isLivePreviewing else { return }
    currentMedia = nil
    isLivePreviewing = true
    isLoading = true
    livePreviewDeviceID = deviceID
    lastError = nil

    do {
      let density = try await adb.screenDensityScale(deviceID: deviceID)
      let session = try await adb.startScreenStream(deviceID: deviceID)
      livePreviewSession = session

      let decoder = H264StreamDecoder { [weak self] sample in
        guard let self else { return }
        let boxed = UnsafeSendable(value: sample)
        Task { @MainActor in
          self.livePreviewSampleBufferHandler?(boxed.value)
        }
      } formatHandler: { [weak self] format in
        guard let self else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        Task { @MainActor in
          self.livePreviewMedia = Media(
            kind: .video,
            url: URL(fileURLWithPath: "/dev/null"),
            capturedAt: Date(),
            width: CGFloat(dims.width),
            height: CGFloat(dims.height),
            densityScale: density
          )
          self.isLoading = false
        }
      }
      livePreviewDecoder = decoder

      let decoderRef = UnsafeSendable(value: decoder)
      livePreviewTask = Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        let handle = session.stdoutPipe.fileHandleForReading
        do {
          while !Task.isCancelled {
            guard let data = try handle.read(upToCount: 4096), !data.isEmpty else { break }
            decoderRef.value.append(data)
          }
        } catch {
          await MainActor.run {
            self.stopLivePreview(error: error)
          }
          return
        }
        await MainActor.run {
          if self.isLivePreviewing {
            self.stopLivePreview()
          }
        }
      }
    } catch {
      isLivePreviewing = false
      livePreviewDeviceID = nil
      isLoading = false
      lastError = error.localizedDescription
    }
  }

  func stopLivePreview(error: Error? = nil, refreshPreview: Bool = false) {
    let deviceID = livePreviewDeviceID
    livePreviewTask?.cancel()
    livePreviewTask = nil
    livePreviewSession?.process.terminate()
    livePreviewSession = nil
    livePreviewDecoder = nil
    if let error {
      lastError = error.localizedDescription
    }
    isLivePreviewing = false
    isLoading = false
    livePreviewDeviceID = nil
    livePreviewMedia = nil
    livePreviewSampleBufferHandler = nil

    if refreshPreview, let deviceID {
      Task { [weak self] in
        await self?.refreshPreview(for: deviceID)
      }
    }
  }
}

/// Read PNG pixel size using ImageIO (no NSImage necessary).
private func pngSize(from data: Data) throws -> (Int, Int) {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
  else {
    throw CocoaError(.fileReadCorruptFile)
  }
  return (width, height)
}

private struct UnsafeSendable<T>: @unchecked Sendable {
  let value: T
}
