import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct CaptureExportSandboxTests {
  static func main() async throws {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let source = directory.deletingLastPathComponent().appendingPathComponent("source.png")
    let context = CGContext(
      data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
    let writer = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(writer))
    let original = try Data(contentsOf: source)

    // Model a save-panel grant: the selected files are writable, but sibling files are not.
    do {
      try original.write(to: directory.appendingPathComponent(".unselected.png"))
      fatalError("Sandbox must reject writes to unselected sibling files")
    } catch {
      precondition((error as NSError).domain == NSCocoaErrorDomain)
      precondition((error as NSError).code == NSFileWriteNoPermissionError)
    }

    let capture = makeCapture(source)
    let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    let uncropped = directory.appendingPathComponent("uncropped.png")
    let cropped = directory.appendingPathComponent("cropped.png")
    let image = directory.appendingPathComponent("image.png")

    // Exercise both creating a new selected file and replacing an existing selected file.
    for replacing in [false, true] {
      if replacing {
        for destination in [uncropped, cropped, image] {
          try Data([0xFF]).write(to: destination)
        }
      }
      try await CaptureCropExporter.save(
        CaptureExportRequest(
          capture: capture,
          crop: CaptureCropGeometry.fullImage
        ),
        to: uncropped
      )
      try checkBytes(uncropped, expected: original)
      try await CaptureCropExporter.save(
        CaptureExportRequest(
          capture: capture,
          crop: crop
        ),
        to: cropped
      )
      try checkCrop(cropped)
      try CaptureCropExporter.saveImage(at: source, crop: crop, to: image)
      try checkCrop(image)
    }

    let missing = directory.deletingLastPathComponent().appendingPathComponent("missing.png")
    do {
      try await CaptureCropExporter.save(
        CaptureExportRequest(
          capture: makeCapture(missing),
          crop: CaptureCropGeometry.fullImage
        ),
        to: uncropped
      )
      fatalError("Missing source must fail to export")
    } catch {}
    try checkBytes(uncropped, expected: original)
    let croppedBytes = try Data(contentsOf: image)
    do {
      try CaptureCropExporter.saveImage(at: missing, crop: crop, to: image)
      fatalError("Missing image must fail to export")
    } catch {}
    try checkBytes(image, expected: croppedBytes)
    try checkBytes(source, expected: original)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    precondition(Set(files) == ["uncropped.png", "cropped.png", "image.png"])
    print("Capture export sandbox tests passed")
  }

  private static func checkBytes(_ url: URL, expected: Data) throws {
    let bytes = try Data(contentsOf: url)
    precondition(bytes == expected)
  }

  private static func checkCrop(_ url: URL) throws {
    let size = try pngSize(from: Data(contentsOf: url))
    precondition(size == CGSize(width: 4, height: 4))
  }

  private static func makeCapture(_ source: URL) -> CaptureMedia {
    CaptureMedia(
      device: Device(id: "test", model: "test", androidVersion: "test", vendorModel: nil, manufacturer: nil, avdName: nil),
      media: .image(
        url: source,
        capturedAt: Date(timeIntervalSince1970: 0),
        display: DisplayInfo(size: CGSize(width: 8, height: 4), densityScale: 1)
      )
    )
  }
}
