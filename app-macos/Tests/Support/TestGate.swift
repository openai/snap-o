import Foundation

actor TestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var waitCount = 0 {
    didSet { testChanges.signal() }
  }

  func wait() async {
    waitCount += 1
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }
}

let testChanges = TestSignal()

@MainActor
func waitForObservedTestState(
  _ condition: @escaping @MainActor @Sendable () -> Bool,
  message: String = "Test state wait was cancelled", file: StaticString = #file, line: UInt = #line
) async {
  do { try await waitForState(condition) }
  catch { preconditionFailure(message, file: file, line: line) }
}

@MainActor
func waitForActorTestState(
  _ condition: () async -> Bool,
  message: String = "Test state wait was cancelled", file: StaticString = #file, line: UInt = #line
) async {
  while true {
    let revision = testChanges.revision
    if await condition() { return }
    do { try await testChanges.wait(after: revision) }
    catch { preconditionFailure(message, file: file, line: line) }
  }
}

/// Start a MainActor operation and let it reach its first suspension.
@MainActor
func startTestTask<Value: Sendable>(
  _ operation: @escaping @MainActor () async -> Value
) async -> Task<Value, Never> {
  let entered = TestValue(false)
  let task = Task {
    entered.value = true
    return await operation()
  }
  await waitForObservedTestState { entered.value }
  return task
}
