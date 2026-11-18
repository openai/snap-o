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
    #expect(settings.recordingAudio == RecordingAudioSources(playback: true))
    settings.recordDeviceAudio = false
    #expect(AppSettings(defaults: defaults).recordingAudio == RecordingAudioSources())
    defaults.set(true, forKey: "recordMicrophone")
    #expect(AppSettings(defaults: defaults).recordingMicrophone == .device)
    defaults.set("mac", forKey: "recordingMicrophone")
    #expect(AppSettings(defaults: defaults).recordingMicrophone == .computer)
    #expect(defaults.string(forKey: "recordingMicrophone") == "computer")
    settings.recordingMicrophone = .computer
    #expect(AppSettings(defaults: defaults).recordingAudio == RecordingAudioSources(microphone: .computer))
    settings.recordDeviceAudio = true
    #expect(AppSettings(defaults: defaults).recordingAudio == RecordingAudioSources(playback: true, microphone: .computer))
    settings.recordingMicrophone = .off
    #expect(AppSettings(defaults: defaults).recordingAudio == RecordingAudioSources(playback: true))
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
