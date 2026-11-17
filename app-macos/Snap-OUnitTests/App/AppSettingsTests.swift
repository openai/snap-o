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
    #expect(settings.recordingAudioMode == .playback)
    settings.recordDeviceAudio = false
    #expect(AppSettings(defaults: defaults).recordingAudioMode == .off)
    settings.recordMicrophone = true
    #expect(AppSettings(defaults: defaults).recordingAudioMode == .microphone)
    settings.recordDeviceAudio = true
    #expect(AppSettings(defaults: defaults).recordingAudioMode == .both)
    settings.recordMicrophone = false
    #expect(AppSettings(defaults: defaults).recordingAudioMode == .playback)
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
