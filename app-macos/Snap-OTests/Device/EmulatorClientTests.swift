import Foundation
@testable import Snap_O
import Testing

@MainActor
struct EmulatorClientTests {
  @Test(arguments: [CocoaError.Code.xpcConnectionInterrupted, .xpcConnectionInvalid])
  func backgroundProxyErrorsReachMainActor(code: CocoaError.Code) async {
    let error = NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: [
      NSLocalizedDescriptionKey: "Synthetic XPC failure"
    ])
    let message = await withCheckedContinuation { continuation in
      let handler = EmulatorClient.proxyErrorHandler { message in
        MainActor.preconditionIsolated()
        continuation.resume(returning: message)
      }
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        handler(error)
      }
    }
    #expect(message == error.localizedDescription)
  }
}
