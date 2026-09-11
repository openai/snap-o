import Foundation
import Observation

@Observable
@MainActor
final class LivePreviewConnection {
  var hasFailed = false
  @ObservationIgnored var cleanupTask: Task<Void, Never>?
}
