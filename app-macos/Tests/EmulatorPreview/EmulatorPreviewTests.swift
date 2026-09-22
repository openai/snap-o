@preconcurrency import AVFoundation
import CryptoKit
import Foundation

@main
struct EmulatorPreviewTests {
  static func main() throws {
    try convertsPixels()
    try boundsRetainedFrames()
    try resizePreservesPreviousFrame()
    try validatesFrames()
    try discoversAuthenticatedEndpoint()
    try discoversUnauthenticatedEndpoint()
    try rejectsStoppedEmulator()
    try rejectsUnsupportedEndpoints()
    try signsJWTForScreenshotOnly()
    print("Emulator preview tests passed (pixels, buffer limits, resize, and endpoint discovery)")
  }

  static func convertsPixels() throws {
    let builder = EmulatorPreviewFrameBuilder()
    // Distinct corners detect channel swaps, row-stride mistakes, and vertical flips.
    let rgba = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255])
    let sample = try builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: 0)!
    let buffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    precondition(Array(UnsafeBufferPointer(start: bytes, count: 8)) == [0, 0, 255, 255, 0, 255, 0, 255])
    precondition(Array(UnsafeBufferPointer(start: bytes + stride, count: 8)) == [255, 0, 0, 255, 30, 20, 10, 255])
  }

  static func boundsRetainedFrames() throws {
    let builder = EmulatorPreviewFrameBuilder()
    let rgba = Data(repeating: 255, count: 16)
    var samples = try (0 ..< 4).map {
      try builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: UInt64($0))!
    }
    let overflow = try builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: 4)
    precondition(overflow == nil, "A slow renderer must not grow the buffer pool")
    samples.removeLast()
    let resumed = try builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: 5)
    precondition(resumed != nil, "Delivery resumes when the renderer releases a frame")
    withExtendedLifetime(samples) {}
  }

  static func resizePreservesPreviousFrame() throws {
    let builder = EmulatorPreviewFrameBuilder()
    let original = try builder.makeSample(rgba: Data(repeating: 255, count: 16), width: 2, height: 2, timestamp: 0)!
    let resized = try builder.makeSample(rgba: Data(repeating: 0, count: 12), width: 3, height: 1, timestamp: 1)!
    let dimensions = CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(resized)!)
    precondition(dimensions.width == 3 && dimensions.height == 1)
    let originalBuffer = CMSampleBufferGetImageBuffer(original)!
    precondition(CVPixelBufferGetWidth(originalBuffer) == 2 && CVPixelBufferGetHeight(originalBuffer) == 2)
  }

  static func validatesFrames() throws {
    let builder = EmulatorPreviewFrameBuilder()
    for (width, height, bytes) in [(0, 1, 0), (2, 2, 15), (Int.max, 2, 0), (8192, 8192, 0)] {
      do {
        _ = try builder.makeSample(rgba: Data(count: bytes), width: width, height: height, timestamp: 0)
        fatalError("Invalid frame accepted")
      } catch is EmulatorPreviewError {}
    }
  }

  static func signsJWTForScreenshotOnly() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    let keys = directory.appendingPathComponent("keys")
    let active = directory.appendingPathComponent("active.jwk")
    try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
    let registration = "port.serial=5554\ngrpc.port=8554\ngrpc.jwks=\(keys.path)\ngrpc.jwk_active=\(active.path)\n"
    try registration.write(to: directory.appendingPathComponent("pid_123.ini"), atomically: true, encoding: .utf8)
    let worker = DispatchGroup()
    worker.enter()
    DispatchQueue.global().async {
      defer { worker.leave() }
      let deadline = Date().addingTimeInterval(2)
      while Date() < deadline {
        let files = (try? FileManager.default.contentsOfDirectory(at: keys, includingPropertiesForKeys: nil)) ?? []
        if let file = files.first(where: { $0.pathExtension == "jwk" }),
           let data = try? Data(contentsOf: file) {
          try? data.write(to: active, options: .atomic)
          return
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    defer { worker.wait() }
    let discovery = EmulatorPreviewDiscovery(home: home, isProcessRunning: { $0 == 123 })
    let endpoint = try discovery.endpoint(for: "emulator-5554")
    let parts = endpoint.token!.split(separator: ".").map(String.init)
    precondition(parts.count == 3)
    func decode(_ value: String) -> Data {
      let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      return Data(base64Encoded: padded + String(repeating: "=", count: (4 - padded.count % 4) % 4))!
    }
    let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
    precondition(claims["aud"] as? [String] == ["/android.emulation.control.EmulatorController/streamScreenshot"])
    let keySet = try JSONSerialization.jsonObject(with: Data(contentsOf: active)) as! [String: Any]
    let key = (keySet["keys"] as! [[String: Any]])[0]
    let publicKey = try P256.Signing.PublicKey(rawRepresentation: decode(key["x"] as! String) + decode(key["y"] as! String))
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
    precondition(publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
  }

  static func discoversAuthenticatedEndpoint() throws {
    try withRegistration("port.serial=5554\ngrpc.port=8554\ngrpc.token=synthetic-token\n") { discovery in
      let endpoint = try discovery.endpoint(for: "emulator-5554")
      precondition(endpoint.port == 8554 && endpoint.token == "synthetic-token")
    }
  }

  static func discoversUnauthenticatedEndpoint() throws {
    try withRegistration("port.serial=5554\ngrpc.port=8554\n") { discovery in
      let endpoint = try discovery.endpoint(for: "emulator-5554")
      precondition(endpoint.port == 8554 && endpoint.token == nil)
    }
  }

  static func rejectsStoppedEmulator() throws {
    try withRegistration("port.serial=5554\ngrpc.port=8554\n", running: false) { discovery in
      try expectUnavailable(discovery)
    }
  }

  static func rejectsUnsupportedEndpoints() throws {
    for settings in ["grpc.port=0", "grpc.port=8554\ngrpc.server_cert=test", "grpc.port=8554\ngrpc.certificate=test"] {
      try withRegistration("port.serial=5554\n" + settings) { discovery in
        try expectUnavailable(discovery)
      }
    }
  }

  private static func expectUnavailable(_ discovery: EmulatorPreviewDiscovery) throws {
    do {
      _ = try discovery.endpoint(for: "emulator-5554")
      fatalError("Unavailable endpoint accepted")
    } catch is EmulatorServiceError {}
  }

  private static func withRegistration(
    _ registration: String,
    running: Bool = true,
    test: (EmulatorPreviewDiscovery) throws -> Void
  ) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try registration.write(to: directory.appendingPathComponent("pid_123.ini"), atomically: true, encoding: .utf8)
    try test(EmulatorPreviewDiscovery(home: home, isProcessRunning: { $0 == 123 && running }))
  }
}
