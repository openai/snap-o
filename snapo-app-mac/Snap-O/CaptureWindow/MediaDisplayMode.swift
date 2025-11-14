import Foundation
import Observation

@Observable
@MainActor
final class MediaDisplayMode {
  private let snapshotController: CaptureSnapshotController

  init(snapshotController: CaptureSnapshotController) {
    self.snapshotController = snapshotController
  }

  var mediaList: [CaptureMedia] { snapshotController.mediaList }
  var selectedMediaID: CaptureMedia.ID? { snapshotController.selectedMediaID }
  var currentCaptureViewID: UUID? { snapshotController.currentCaptureViewID }
  var shouldShowPreviewHint: Bool { snapshotController.shouldShowPreviewHint }
  var overlayMediaList: [CaptureMedia] { snapshotController.overlayMediaList }
  var lastViewedDeviceID: String? { snapshotController.lastViewedDeviceID }
  var currentCapture: CaptureMedia? { snapshotController.currentCapture }
  var captureProgressText: String? { snapshotController.captureProgressText }
  var lastPreviewDisplayInfo: DisplayInfo? { snapshotController.lastPreviewDisplayInfo }

  func selectMedia(id: CaptureMedia.ID?) {
    snapshotController.selectMedia(id: id)
  }

  func selectMedia(id: CaptureMedia.ID) {
    snapshotController.selectMedia(id: id)
  }

  func selectNextMedia() {
    snapshotController.selectNextMedia()
  }

  func selectPreviousMedia() {
    snapshotController.selectPreviousMedia()
  }

  func updateMediaList(
    _ newMedia: [CaptureMedia],
    preserveDeviceID: String?,
    shouldSort: Bool
  ) {
    snapshotController.updateMediaList(
      newMedia,
      preserveDeviceID: preserveDeviceID,
      shouldSort: shouldSort
    )
  }

  func setPreviewHintHovering(_ hovering: Bool) {
    snapshotController.setPreviewHintHovering(hovering)
  }

  func setProgressHovering(_ hovering: Bool) {
    snapshotController.setProgressHovering(hovering)
  }

  func requestPreviewHint(transient: Bool) {
    snapshotController.requestPreviewHint(transient: transient)
  }

  func updateLastViewedDeviceID(_ id: String?) {
    snapshotController.updateLastViewedDeviceID(id)
  }

  func clearSelection() {
    snapshotController.clearSelection()
  }

  func tearDown() {
    snapshotController.tearDown()
  }
}
