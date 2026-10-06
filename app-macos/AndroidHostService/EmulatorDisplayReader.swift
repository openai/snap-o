import Foundation

/// Adapts the app's asynchronous display probe to the console's serial worker.
struct EmulatorDisplayReader {
  let provider: any EmulatorDisplayProvider

  func read() throws -> String {
    let response = Response()
    provider.readDisplay { value, error in response.complete(value: value, error: error) }
    guard response.ready.wait(timeout: .now() + 3) == .success else {
      throw AndroidHostServiceError(message: "The app did not respond while reading the emulator display.")
    }
    return try response.result.get()
  }

  private final class Response: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Result<String, Error>?
    var result: Result<String, Error> {
      lock.withLock { value ?? .failure(AndroidHostServiceError(message: "The emulator display is unavailable.")) }
    }

    func complete(value: String?, error: String?) {
      lock.withLock {
        guard self.value == nil else { return }
        if let error {
          self.value = .failure(AndroidHostServiceError(message: error))
        } else if let value {
          self.value = .success(value)
        } else {
          self.value = .failure(AndroidHostServiceError(message: "The emulator display is unavailable."))
        }
        ready.signal()
      }
    }
  }
}
