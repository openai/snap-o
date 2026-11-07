import Clocks
import Dependencies
import Testing

struct ToolConnectionHealthTests {
  @Test
  func probesInitiallyAndAfterQuietPeriod() async {
    let clock = TestClock()
    let health = ToolConnectionHealth(clock: AnyClock(clock))
    #expect(health.needsProbe)
    health.recordActivity()
    #expect(!health.needsProbe)
    await clock.advance(by: .seconds(44))
    #expect(!health.needsProbe)
    await clock.advance(by: .seconds(1))
    #expect(health.needsProbe)
  }

  @Test
  func idleHeartbeatsKeepTheConnectionHealthy() async {
    let clock = TestClock()
    let health = ToolConnectionHealth(clock: AnyClock(clock))
    health.recordActivity()
    for _ in 0 ..< 5 {
      await clock.advance(by: .seconds(30))
      #expect(!health.needsProbe)
      health.recordActivity()
    }
    await clock.advance(by: .seconds(45))
    #expect(health.needsProbe)
  }

  @Test
  func failureRequestsAProbeWithoutOverridingNewActivity() {
    let health = ToolConnectionHealth(clock: AnyClock(TestClock()))
    health.recordActivity()
    let oldRequest = health.revision
    health.recordActivity()
    health.requestFailed(since: oldRequest)
    #expect(!health.needsProbe)
    health.requestFailed(since: health.revision)
    #expect(health.needsProbe)
  }
}
