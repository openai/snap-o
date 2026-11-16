struct RecordingOptions {
  let recordsBugReport: Bool
  let showsTouches: Bool
  let recordsDeviceAudio: Bool
  let recordsMicrophone: Bool

  init(recordsBugReport: Bool, showsTouches: Bool, recordsDeviceAudio: Bool = false, recordsMicrophone: Bool = false) {
    self.recordsBugReport = recordsBugReport
    self.showsTouches = showsTouches
    self.recordsDeviceAudio = recordsDeviceAudio
    self.recordsMicrophone = recordsMicrophone
  }
}
