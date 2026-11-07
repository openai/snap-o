import Foundation
@testable import Snap_O
import Testing

/// Checks synchronous cancellation cleanup before allowing the suspended task to resume.
func expectClosedConnection(_ connection: ADBSocketConnection, sourceLocation: SourceLocation = #_sourceLocation) {
  defer { connection.close() }
  do {
    try connection.setIOTimeout(nil)
    Issue.record("Cancellation left the connection open", sourceLocation: sourceLocation)
  } catch ADBError.protocolFailure(let message) {
    #expect(message == "ADB connection closed", sourceLocation: sourceLocation)
  } catch {
    Issue.record("Expected a closed connection, got \(error)", sourceLocation: sourceLocation)
  }
}
