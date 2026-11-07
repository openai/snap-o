import Dependencies
import Foundation
import Testing

struct CaptureTrimExportTests {
  @Test
  func invalidTrimDoesNotStartExportOrChangeFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    let destination = root.appendingPathComponent("saved.mp4")
    try Data("source".utf8).write(to: source)
    try Data("saved".utf8).write(to: destination)
    let capture = CaptureMedia(device: Device(
      id: "test",
      model: "Test",
      androidVersion: "16",
      vendorModel: nil,
      manufacturer: nil,
      avdName: nil
    ), media: .video(
      url: source,
      capturedAt: .now,
      display: DisplayInfo(
        size: CGSize(width: 64, height: 32),
        densityScale: nil
      )
    ))
    await withDependencies {
      $0.videoFiles.inspect = { _ in VideoFileInfo(duration: 3, size: CGSize(width: 64, height: 32)) }
    } operation: {
      await #expect(throws: (any Error).self) {
        try await CaptureCropExporter.save(
          CaptureExportRequest(capture: capture, trim: CaptureTrimRange(start: 2, end: 1)),
          to: destination
        )
      }
    }
    #expect(try Data(contentsOf: source) == Data("source".utf8))
    #expect(try Data(contentsOf: destination) == Data("saved".utf8))
  }
}
