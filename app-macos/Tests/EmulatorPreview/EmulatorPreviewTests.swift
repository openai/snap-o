@preconcurrency import AVFoundation
import CryptoKit
import Foundation

@main
struct EmulatorPreviewTests {
  static func main() throws {
    try convertsAndRetainsFrames()
    try validatesFrames()
    try discoversEndpoints()
    try signsJWTForScreenshotOnly()
    print("Emulator preview tests passed (pixels, buffer limits, resize, and endpoint discovery)")
  }

  static func convertsAndRetainsFrames() throws {
    let builder = EmulatorPreviewFrameBuilder()
    // Distinct corners detect channel swaps, row-stride mistakes, and accidental vertical flips.
    let rgba = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255])
    var samples: [CMSampleBuffer] = []
    for _ in 0 ..< 4 {
      try samples.append(builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: 123)!)
    }
    let overflow = try builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: 124)
    precondition(overflow == nil)
    let buffer = CMSampleBufferGetImageBuffer(samples[0])!
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    precondition(Array(UnsafeBufferPointer(start: bytes, count: 8)) == [0, 0, 255, 255, 0, 255, 0, 255])
    precondition(Array(UnsafeBufferPointer(start: bytes + stride, count: 8)) == [255, 0, 0, 255, 30, 20, 10, 255])
    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    precondition(CMSampleBufferGetPresentationTimeStamp(samples[0]) == CMTime(value: 123, timescale: 1_000_000))
    samples.removeLast()
    let reused = try builder.makeSample(rgba: rgba, width: 2, height: 2, timestamp: 125)
    precondition(reused != nil)
    let resized = try builder.makeSample(rgba: Data(repeating: 0, count: 12), width: 3, height: 1, timestamp: 126)!
    precondition(CVPixelBufferGetWidth(CMSampleBufferGetImageBuffer(resized)!) == 3)
    precondition(CVPixelBufferGetWidth(buffer) == 2, "Resize must not mutate displayed frames")
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
    _ = try discovery.endpoint(for: "emulator-5554")
    let files = try FileManager.default.contentsOfDirectory(at: keys, includingPropertiesForKeys: nil)
    precondition(files.count == 1, "Repeated discovery should reuse the public key")
  }

  static func discoversEndpoints() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let live = directory.appendingPathComponent("pid_123.ini")
    let dead = directory.appendingPathComponent("pid_124.ini")
    try "port.serial=5556\ngrpc.port=8556\ngrpc.token=synthetic-token\n".write(to: live, atomically: true, encoding: .utf8)
    try "port.serial=5554\ngrpc.port=8554\n".write(to: dead, atomically: true, encoding: .utf8)
    let discovery = EmulatorPreviewDiscovery(home: home, isProcessRunning: { $0 == 123 })
    let endpoint = try discovery.endpoint(for: "emulator-5556")
    precondition(endpoint.port == 8556 && endpoint.token == "synthetic-token")
    for serial in ["emulator-5554", "phone", "emulator-invalid"] {
      do {
        _ = try discovery.endpoint(for: serial)
        fatalError("Unavailable endpoint accepted")
      } catch is EmulatorServiceError {}
    }
    try "port.serial=5556\ngrpc.port=8556\n".write(to: live, atomically: true, encoding: .utf8)
    let unauthenticated = try discovery.endpoint(for: "emulator-5556")
    precondition(unauthenticated.token == nil)
    for extra in ["grpc.server_cert=test", "grpc.certificate=test", "grpc.port=0"] {
      try ("port.serial=5556\ngrpc.port=8556\n" + extra).write(to: live, atomically: true, encoding: .utf8)
      do {
        _ = try discovery.endpoint(for: "emulator-5556")
        fatalError("Unsupported endpoint accepted")
      } catch is EmulatorServiceError {}
    }
  }
}
