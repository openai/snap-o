import Foundation
import Testing

@MainActor
struct AppSettingsTests {
  @Test
  func defaultsToDeviceAudioAndRemembersEachAudioSource() throws {
    let suite = "AppSettingsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.recordDeviceAudio)
    #expect(!settings.recordMicrophone)
    settings.recordDeviceAudio = false
    #expect(!AppSettings(defaults: defaults).recordDeviceAudio)
    settings.recordMicrophone = true
    #expect(!AppSettings(defaults: defaults).recordDeviceAudio)
    #expect(AppSettings(defaults: defaults).recordMicrophone)
    settings.recordDeviceAudio = true
    settings.recordMicrophone = false
    #expect(AppSettings(defaults: defaults).recordDeviceAudio)
    #expect(!AppSettings(defaults: defaults).recordMicrophone)
  }

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
