import Foundation
import Observation

@Observable
@MainActor
final class LivePreviewConnection {
  var hasFailed = false
  var restartID = UUID()
  let thumbnail = LivePreviewThumbnail()
  @ObservationIgnored var cleanupTask: Task<Void, Never>?
}
