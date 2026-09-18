import Foundation
import Observation

@Observable
@MainActor
final class LivePreviewConnection {
  var hasFailed = false
  let thumbnail = LivePreviewThumbnail()
  @ObservationIgnored var cleanupTask: Task<Void, Never>?
}
