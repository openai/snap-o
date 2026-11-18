import Testing

struct RecordingOptionsTests {
  @Test(arguments: [false, true], [RecordingMicrophone.off, .device, .computer])
  func choosesVideoSourceForDeviceAndAudioMode(playback: Bool, microphone: RecordingMicrophone) {
    let audio = RecordingAudioSources(playback: playback, microphone: microphone)
    let options = RecordingOptions(recordsBugReport: false, showsTouches: false, audio: audio)
    #expect(options.videoSource(isLocalEmulator: false) == .sharedPreview)
    #expect(options.videoSource(isLocalEmulator: true) == (!playback && microphone == .off ? .screenrecord : .androidHelper))

    let bugReport = RecordingOptions(recordsBugReport: true, showsTouches: false, audio: audio)
    #expect(bugReport.videoSource(isLocalEmulator: true) == .screenrecord)
    #expect(bugReport.videoSource(isLocalEmulator: false) == .screenrecord)
  }

  @Test(arguments: [false, true])
  func computerMicrophoneLeavesTheAndroidMicrophoneFree(playback: Bool) {
    let sources = RecordingAudioSources(playback: playback, microphone: .computer)
    #expect(sources.deviceMode == (playback ? .playback : .off))
    #expect(sources.available(supportsDeviceAudio: false) == RecordingAudioSources(microphone: .computer))
    #expect(RecordingAudioSources(playback: playback, microphone: .device).available(supportsDeviceAudio: false) == RecordingAudioSources())
  }
}
