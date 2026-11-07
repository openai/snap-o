import Clocks
import Dependencies
import DependenciesTestSupport
import Testing

@MainActor
@Suite(.dependency(\.continuousClock, TestClock()))
struct EmulatorPreviewStartupDeadlineTests {
  @Test
  func inactivePreviewDoesNotExpire() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    var expired = false
    let deadline = EmulatorPreviewStartupDeadline { expired = true }
    deadline.setActive(false)
    await clock.advance(by: .seconds(30))
    await deadline.waitUntilStopped()
    #expect(!expired)
    try await clock.checkSuspension()
  }

  @Test
  func firstActiveRequestStartsTheDeadline() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    var expired = false
    let deadline = EmulatorPreviewStartupDeadline { expired = true }
    await clock.advance(by: .seconds(30))
    deadline.setActive(true)
    await clock.advance(by: .seconds(14))
    #expect(!expired)
    await clock.advance(by: .seconds(1))
    await deadline.waitUntilStopped()
    #expect(expired)
    try await clock.checkSuspension()
  }

  @Test
  func reactivationGetsAFreshDeadline() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    var expired = false
    let deadline = EmulatorPreviewStartupDeadline { expired = true }
    deadline.setActive(true)
    await clock.advance(by: .seconds(10))
    deadline.setActive(false)
    await deadline.waitUntilStopped()
    await clock.advance(by: .seconds(30))
    #expect(!expired)
    deadline.setActive(true)
    await clock.advance(by: .seconds(14))
    #expect(!expired)
    await clock.advance(by: .seconds(1))
    await deadline.waitUntilStopped()
    #expect(expired)
    try await clock.checkSuspension()
  }

  @Test
  func activeResizeDoesNotExtendTheDeadline() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    var expired = false
    let deadline = EmulatorPreviewStartupDeadline { expired = true }
    deadline.setActive(true)
    await clock.advance(by: .seconds(10))
    deadline.setActive(true)
    await clock.advance(by: .seconds(5))
    await deadline.waitUntilStopped()
    #expect(expired)
    try await clock.checkSuspension()
  }

  @Test
  func finishingPreventsLaterRequestsFromRestartingTheDeadline() async throws {
    @Dependency(\.continuousClock, as: TestClock<Duration>.self)
    var clock
    var expired = false
    let deadline = EmulatorPreviewStartupDeadline { expired = true }
    deadline.setActive(true)
    await clock.advance(by: .seconds(10))
    deadline.finish()
    await deadline.waitUntilStopped()
    deadline.setActive(false)
    deadline.setActive(true)
    await clock.advance(by: .seconds(30))
    await deadline.waitUntilStopped()
    #expect(!expired)
    try await clock.checkSuspension()
  }
}
