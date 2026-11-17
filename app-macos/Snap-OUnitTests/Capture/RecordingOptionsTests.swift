import Testing

struct RecordingOptionsTests {
  @Test(arguments: [RecordingAudioMode.off, .playback, .microphone, .both])
  func choosesVideoSourceForDeviceAndAudioMode(audioMode: RecordingAudioMode) {
    let options = RecordingOptions(recordsBugReport: false, showsTouches: false, audioMode: audioMode)
    #expect(options.videoSource(isLocalEmulator: false) == .sharedPreview)
    #expect(options.videoSource(isLocalEmulator: true) == (audioMode == .off ? .screenrecord : .androidHelper))

    let bugReport = RecordingOptions(recordsBugReport: true, showsTouches: false, audioMode: audioMode)
    #expect(bugReport.videoSource(isLocalEmulator: true) == .screenrecord)
    #expect(bugReport.videoSource(isLocalEmulator: false) == .screenrecord)
  }
}
