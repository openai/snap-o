import AVFoundation
import Testing

struct VideoExportSettingsTests {
  @Test(arguments: [false, true])
  func cropUsesDisplayedCoordinates(rotated: Bool) {
    let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    let info = VideoFileInfo(duration: 2, size: CGSize(width: 64, height: 32), transform: rotated ? rotation : .identity)
    let crop = rotated ? CGRect(x: 0, y: 0.5, width: 1, height: 0.5) : CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    let range = CMTimeRange(start: CMTime(value: 1, timescale: 4), end: CMTime(value: 1, timescale: 1))
    let settings = VideoExportSettings(info: info, crop: crop, timeRange: range)
    #expect(settings.size == CGSize(width: 32, height: 32))
    #expect(settings.appliesCrop)
    #expect(settings.timeRange == range)
    let expected = rotated ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: -32)
      : CGAffineTransform(translationX: -32, y: 0)
    #expect(settings.transform == expected)
  }

  @Test
  func fullFrameNeedsNoComposition() {
    let info = VideoFileInfo(duration: 2, size: CGSize(width: 64, height: 32))
    let settings = VideoExportSettings(info: info, crop: CGRect(x: 0, y: 0, width: 1, height: 1), timeRange: nil)
    #expect(!settings.appliesCrop)
    #expect(settings.timeRange == nil)
    #expect(settings.size == info.size)
  }

  @Test
  func cropRoundsOutwardToEvenPixels() {
    let rect = VideoExportSettings.pixelRect(
      CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
      size: CGSize(width: 30, height: 30),
      alignment: 2
    )
    #expect(rect == CGRect(x: 2, y: 2, width: 16, height: 16))
  }
}
