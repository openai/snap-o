import Foundation
import Synchronization

/// Keeps console commands ordered while the app reads its selected device.
struct EmulatorDisplayReader {
  let provider: any EmulatorDisplayProvider

  func read() throws -> String {
    let response = Mutex<Result<String, Error>?>(nil)
    let ready = DispatchSemaphore(value: 0)
    provider.readDisplay { value, error in
      response.withLock { result in
        guard result == nil else { return }
        if let value, error == nil {
          result = .success(value)
        } else {
          result = .failure(AndroidHostServiceError(message: error ?? "The emulator display is unavailable."))
        }
        ready.signal()
      }
    }
    let completed = ready.wait(timeout: .now() + 3)
    return try response.withLock { result in
      guard completed == .success, let result else {
        throw AndroidHostServiceError(message: "The app did not respond while reading the emulator display.")
      }
      return try result.get()
    }
  }
}
