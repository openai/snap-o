import Foundation
@testable import Snap_O
import Testing

@MainActor
struct AppSettingsTests {
  @Test
  func restoresLastViewedDevice() throws {
    let suite = "AppSettingsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.lastViewedDeviceID == nil)
    settings.lastViewedDeviceID = "test-device"
    #expect(AppSettings(defaults: defaults).lastViewedDeviceID == "test-device")
    settings.lastViewedDeviceID = nil
    #expect(AppSettings(defaults: defaults).lastViewedDeviceID == nil)
  }
}
