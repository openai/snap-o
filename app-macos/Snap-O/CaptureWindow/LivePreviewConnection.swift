import Foundation
import Observation

@Observable
@MainActor
final class LivePreviewConnection {
  var hasFailed = false
  var restartID = UUID()
  var clipboard: ClipboardSync?
  let thumbnail = LivePreviewThumbnail()
  @ObservationIgnored var cleanupTask: Task<Void, Never>?
}
