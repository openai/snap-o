import Foundation
import SwiftUI

@MainActor
final class CaptureSnapshotController: ObservableObject {
  @Published private(set) var mediaList: [CaptureMedia] = []
  @Published private(set) var selectedMediaID: CaptureMedia.ID?
  @Published private(set) var currentCaptureViewID: UUID?
  @Published private(set) var shouldShowPreviewHint: Bool = false
  @Published private(set) var overlayMediaList: [CaptureMedia] = []

  private var previewHintTask: Task<Void, Never>?
  private var isPreviewHintHovered = false
  private var currentCaptureSnapshot: CaptureMedia?
  private var currentCaptureSource: CaptureMedia?

  private(set) var lastPreviewDisplayInfo: DisplayInfo?
  private(set) var lastViewedDeviceID: String?

  var currentCapture: CaptureMedia? { currentCaptureSnapshot }

  var captureProgressText: String? {
    guard mediaList.count > 1,
          let selectedID = selectedMediaID,
          let index = mediaList.firstIndex(where: { $0.id == selectedID })
    else { return nil }
    return "\(index + 1)/\(mediaList.count)"
  }

  var hasAlternativeMedia: Bool { mediaList.count > 1 }

  func selectMedia(id: CaptureMedia.ID) {
    selectMedia(id: Optional(id))
  }

  func selectMedia(id: CaptureMedia.ID?) {
    guard selectedMediaID != id else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      selectedMediaID = id
      let baseCapture = capture(for: id) ?? mediaList.first
      updateCurrentCaptureSnapshotIfNeeded(with: baseCapture)
      await showPreviewHintIfNeeded(transient: true)
    }
  }

  func selectNextMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id)
      return
    }
    let nextIndex = (currentIndex + 1) % mediaList.count
    selectMedia(id: mediaList[nextIndex].id)
  }

  func selectPreviousMedia() {
    guard !mediaList.isEmpty else { return }
    guard let currentID = selectedMediaID,
          let currentIndex = mediaList.firstIndex(where: { $0.id == currentID })
    else {
      selectMedia(id: mediaList.first?.id)
      return
    }
    let previousIndex = (currentIndex - 1 + mediaList.count) % mediaList.count
    selectMedia(id: mediaList[previousIndex].id)
  }

  func updateMediaList(
    _ newMedia: [CaptureMedia],
    preserveDeviceID: String?,
    shouldSort: Bool
  ) {
    if shouldShowPreviewHint {
      dismissPreviewHintImmediately()
    }

    var ordered = shouldSort ? newMedia.sorted { $0.device.displayTitle < $1.device.displayTitle } : newMedia

    if let preserve = preserveDeviceID,
       let index = ordered.firstIndex(where: { $0.device.id == preserve }),
       index != ordered.startIndex {
      let preferred = ordered.remove(at: index)
      ordered.insert(preferred, at: ordered.startIndex)
    }

    mediaList = ordered

    if ordered.isEmpty {
      selectedMediaID = nil
    } else if let preserve = preserveDeviceID,
              let preserved = ordered.first(where: { $0.device.id == preserve }) {
      selectedMediaID = preserved.id
    } else if let currentID = selectedMediaID,
              ordered.contains(where: { $0.id == currentID }) {
      // Keep current selection
    } else {
      selectedMediaID = ordered.first?.id
    }

    let baseCapture: CaptureMedia? = if let currentID = selectedMediaID {
      ordered.first { $0.id == currentID }
    } else {
      ordered.first
    }

    updateCurrentCaptureSnapshotIfNeeded(with: baseCapture)
    Task { @MainActor [weak self] in
      await self?.showPreviewHintIfNeeded(transient: true)
    }
  }

  func setPreviewHintHovering(_ isHovering: Bool) {
    if isHovering {
      isPreviewHintHovered = true
      previewHintTask?.cancel()
      previewHintTask = nil
    } else {
      isPreviewHintHovered = false
      if shouldShowPreviewHint {
        schedulePreviewHintDismiss(after: 0.5)
      }
    }
  }

  func setProgressHovering(_ isHovering: Bool) {
    if isHovering {
      setPreviewHintHovering(true)
      Task { @MainActor [weak self] in
        await self?.showPreviewHintIfNeeded(transient: false)
      }
    } else {
      setPreviewHintHovering(false)
    }
  }

  func requestPreviewHint(transient: Bool) {
    Task { @MainActor [weak self] in
      await self?.showPreviewHintIfNeeded(transient: transient)
    }
  }

  func tearDown() {
    previewHintTask?.cancel()
    previewHintTask = nil
    shouldShowPreviewHint = false
    overlayMediaList = []
    isPreviewHintHovered = false
    currentCaptureSnapshot = nil
    currentCaptureSource = nil
    currentCaptureViewID = nil
    lastPreviewDisplayInfo = nil
    lastViewedDeviceID = nil
  }

  func updateLastViewedDeviceID(_ id: String?) {
    lastViewedDeviceID = id
  }

  func clearSelection() {
    selectedMediaID = nil
    updateCurrentCaptureSnapshotIfNeeded(with: nil)
  }

  private func capture(for id: CaptureMedia.ID?) -> CaptureMedia? {
    guard let id else { return nil }
    return mediaList.first { $0.id == id }
  }

  private func updateCurrentCaptureSnapshotIfNeeded(with baseCapture: CaptureMedia?) {
    guard let baseCapture else {
      currentCaptureSnapshot = nil
      currentCaptureSource = nil
      currentCaptureViewID = nil
      lastPreviewDisplayInfo = nil
      return
    }

    let didChangeCapture = currentCaptureSource?.id != baseCapture.id

    currentCaptureSnapshot = baseCapture
    currentCaptureSource = baseCapture
    lastPreviewDisplayInfo = baseCapture.media.common.display

    if didChangeCapture {
      currentCaptureViewID = UUID()
    }

    lastViewedDeviceID = baseCapture.device.id
  }

  private func showPreviewHintIfNeeded(transient: Bool) async {
    await Task.yield()

    guard mediaList.count > 1 else {
      shouldShowPreviewHint = false
      previewHintTask?.cancel()
      previewHintTask = nil
      isPreviewHintHovered = false
      overlayMediaList = []
      return
    }

    previewHintTask?.cancel()
    previewHintTask = nil

    overlayMediaList = mediaList
    shouldShowPreviewHint = true

    guard transient else { return }
    schedulePreviewHintDismiss(after: 2)
  }

  private func schedulePreviewHintDismiss(after seconds: Double) {
    previewHintTask?.cancel()
    previewHintTask = Task { [weak self] in
      let delay = UInt64(seconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, !self.isPreviewHintHovered else { return }
        self.shouldShowPreviewHint = false
        self.overlayMediaList = []
        self.previewHintTask = nil
      }
    }
  }

  private func dismissPreviewHintImmediately() {
    previewHintTask?.cancel()
    previewHintTask = nil
    shouldShowPreviewHint = false
    isPreviewHintHovered = false
    overlayMediaList = []
  }
}
