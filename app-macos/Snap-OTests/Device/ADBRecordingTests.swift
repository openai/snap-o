@preconcurrency import AVFoundation
import CoreVideo
import Darwin
import Foundation
@testable import Snap_O
import Testing

@Suite("Recording recovery")
struct ADBRecordingTests {
  @Test("stop recovers a file even when signalling or finalization stalls", arguments: [RecordingTestADB.Stall.stopCommand, .finalization])
  private func recoversAfterStopTimeout(stall: RecordingTestADB.Stall) async throws {
    let server = RecordingTestADB(stall: stall)
    defer { server.close() }
    let client = server.client()
    let session = try await client.startScreenrecord(deviceID: "stalled")
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    let start = ContinuousClock.now
    let warning = try await client.stopScreenrecord(session: session, savingTo: destination)
    #expect(warning is ADBError)
    #expect(try Data(contentsOf: destination) == server.movie)
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(server.removedDevices == ["stalled"])
  }

  @Test(
    "failed downloads remove partial files and preserve the device copy",
    arguments: [RecordingTestADB.Stall.download, .downloadTrickle]
  )
  private func boundsDownload(stall: RecordingTestADB.Stall) async throws {
    let server = RecordingTestADB(stall: stall)
    defer { server.close() }
    let client = server.client()
    let session = try await client.startScreenrecord(deviceID: "stalled")
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    let start = ContinuousClock.now
    do {
      try await client.stopScreenrecord(session: session, savingTo: destination)
      Issue.record("Expected a download timeout")
    } catch ADBError.requestTimedOut {}
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(server.removedDevices.isEmpty)
  }

  @Test("remote cleanup cannot hold a downloaded file", arguments: [RecordingTestADB.Stall.cleanup, .healthy])
  private func boundsCleanup(stall: RecordingTestADB.Stall) async throws {
    let server = RecordingTestADB(stall: stall)
    defer { server.close() }
    let client = server.client()
    let session = try await client.startScreenrecord(deviceID: "stalled")
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    let start = ContinuousClock.now
    let warning = try await client.stopScreenrecord(session: session, savingTo: destination)
    #expect(warning == nil)
    #expect(try Data(contentsOf: destination) == server.movie)
    #expect(start.duration(to: .now) < .seconds(3))
  }

  @Test("recording setup cannot hold Stop indefinitely")
  func boundsSetup() async throws {
    let server = RecordingTestADB(stall: .start)
    defer { server.close() }
    let start = ContinuousClock.now
    do {
      _ = try await server.client().startScreenrecord(deviceID: "stalled")
      Issue.record("Expected setup to time out")
    } catch ADBError.requestTimedOut {}
    #expect(start.duration(to: .now) < .seconds(3))
  }

  @Test("cancellation interrupts finalization and download", arguments: [RecordingTestADB.Stall.finalization, .download])
  private func cancelsStop(stall: RecordingTestADB.Stall) async throws {
    let server = RecordingTestADB(stall: stall)
    defer { server.close() }
    let client = server.client(timeout: .seconds(10))
    let session = try await client.startScreenrecord(deviceID: "stalled")
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    let task = Task { try await client.stopScreenrecord(session: session, savingTo: destination) }
    for await command in server.requests.stream {
      if command == (stall == .finalization ? "kill" : "download") { break }
    }
    let start = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(start.duration(to: .now) < .seconds(2))
  }

  @Test("discarding a recording also bounds finalization")
  func boundsDiscard() async throws {
    let server = RecordingTestADB(stall: .finalization)
    defer { server.close() }
    let client = server.client()
    let session = try await client.startScreenrecord(deviceID: "stalled")
    let start = ContinuousClock.now
    await client.cancelScreenrecord(session: session)
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(server.removedDevices == ["stalled"])
  }

  @Test("healthy recordings survive another device's failure and release capture leases")
  func returnsPartialResults() async throws {
    let server = try await RecordingTestADB(stall: .download, movie: makeMovie())
    defer { server.close() }
    let directory = temporaryFile().deletingPathExtension()
    let store = FileStore(baseDir: directory)
    defer { store.purgeExistingFiles() }
    let coordinator = CaptureCoordinator()
    let service = RecordingService(adb: ADBService(client: server.client()), fileStore: store, coordinator: coordinator)
    let handle = try await service.start(for: [device("stalled"), device("phone")], options: options)
    await service.finish(handle)
    let result = try #require(await service.waitForCompletion(of: handle))
    #expect(result.media.map(\.device.id) == ["phone"])
    #expect(result.media.first?.media.isVideo == true)
    #expect(result.error?.localizedDescription.contains("stalled") == true)
    #expect(result.error?.localizedDescription.contains("timed out") == true)
    let lease = try await coordinator.acquire(deviceIDs: ["stalled", "phone"], for: .recording)
    await coordinator.release(lease)
    await service.shutdown()
  }

  @Test("recovered media remains playable with a finalization warning")
  func returnsRecoveredMedia() async throws {
    let server = try await RecordingTestADB(stall: .finalization, movie: makeMovie())
    defer { server.close() }
    let store = FileStore(baseDir: temporaryFile().deletingPathExtension())
    defer { store.purgeExistingFiles() }
    let service = RecordingService(adb: ADBService(client: server.client()), fileStore: store, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: [device("stalled")], options: options)
    await service.finish(handle)
    let result = try #require(await service.waitForCompletion(of: handle))
    #expect(result.media.count == 1)
    #expect(result.media.first?.media.isVideo == true)
    #expect(result.error?.localizedDescription.contains("finalization timed out") == true)
    await service.shutdown()
  }

  @Test(
    "optional device settings and metadata cannot hide a saved recording",
    arguments: [RecordingTestADB.Stall.settingsRestore, .density]
  )
  private func boundsOptionalRequests(stall: RecordingTestADB.Stall) async throws {
    let server = try await RecordingTestADB(stall: stall, movie: makeMovie())
    defer { server.close() }
    let store = FileStore(baseDir: temporaryFile().deletingPathExtension())
    defer { store.purgeExistingFiles() }
    let service = RecordingService(adb: ADBService(client: server.client()), fileStore: store, coordinator: CaptureCoordinator())
    let handle = try await service.start(for: [device("stalled")], options: options)
    let start = ContinuousClock.now
    await service.finish(handle)
    let result = try #require(await service.waitForCompletion(of: handle))
    #expect(result.media.count == 1)
    #expect(start.duration(to: .now) < .seconds(9))
    await service.shutdown()
  }

  private var options: RecordingOptions {
    RecordingOptions(recordsBugReport: false, showsTouches: true)
  }

  private func device(_ id: String) -> Device {
    Device(id: id, model: id, androidVersion: "16", vendorModel: nil, manufacturer: nil, avdName: nil)
  }

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID()).mp4")
  }

  private func makeMovie() async throws -> Data {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) {
      memset(base, 0, CVPixelBufferGetDataSize(pixels))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !input.isReadyForMoreMediaData, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(adaptor.append(pixels, withPresentationTime: .zero))
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed)
    return try Data(contentsOf: url)
  }
}

private final class RecordingTestADB: @unchecked Sendable {
  enum Stall {
    case healthy, start, stopCommand, finalization, download, downloadTrickle, cleanup, settingsRestore, density
  }

  let movie: Data
  let requests = AsyncStream<String>.makeStream()
  private let stall: Stall
  private let lock = NSLock()
  private let workers = DispatchGroup()
  private var peers: [ADBSocketConnection] = []
  private var recordings: [String: ADBSocketConnection] = [:]
  private var removed: [String] = []

  init(stall: Stall, movie: Data = Data("synthetic recording".utf8)) {
    self.stall = stall
    self.movie = movie
  }

  var removedDevices: [String] {
    lock.withLock { removed }
  }

  func client(timeout: Duration = .milliseconds(200)) -> ADBClient {
    ADBClient(
      discoveryTimeout: timeout,
      recordingTimeouts: .init(command: timeout, finalization: timeout, download: timeout * 3, downloadIdle: timeout)
    ) { try self.connect() }
  }

  func close() {
    lock.withLock { peers.forEach { $0.close() } }
    workers.wait()
    requests.continuation.finish()
  }

  private func connect() throws -> ADBSocketConnection {
    var sockets: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
    for descriptor in sockets {
      var noSigPipe: Int32 = 1
      _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }
    let connection = ADBSocketConnection(connectedSocket: sockets[0])
    let peer = ADBSocketConnection(connectedSocket: sockets[1])
    lock.withLock { peers.append(peer) }
    workers.enter()
    DispatchQueue.global().async {
      defer { self.workers.leave() }
      do {
        try peer.withRequestTimeout(.seconds(3)) { try self.serve(peer) }
      } catch {
        peer.close()
      }
    }
    return connection
  }

  private func serve(_ peer: ADBSocketConnection) throws {
    let transport = try readRequest(peer)
    let device = String(transport.dropFirst("host:transport:".count))
    let behavior = device == "stalled" ? stall : .healthy
    try peer.writeFully(Data("OKAY".utf8))
    let command = try readRequest(peer)
    if command.contains("kill -INT") {
      requests.continuation.yield("kill")
      if behavior == .stopCommand { return }
    }
    try peer.writeFully(Data("OKAY".utf8))
    if command.contains("echo $$; exec screenrecord") {
      if behavior == .start { return }
      lock.withLock { recordings[device] = peer }
      try peer.writeLine("42")
      return
    }
    if command == "sync:" {
      let header = try read(peer, count: 8)
      let size = header.suffix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
      _ = try read(peer, count: size + 1)
      requests.continuation.yield("download")
      if behavior == .download {
        try peer.writeFully(syncFrame("DATA", size: 64) + Data("part".utf8))
        return
      }
      if behavior == .downloadTrickle {
        for _ in 0 ..< 100 {
          try peer.writeFully(syncFrame("DATA", size: 1) + Data("x".utf8))
          Thread.sleep(forTimeInterval: 0.03)
        }
        return
      }
      try peer.writeFully(syncFrame("DATA", size: movie.count) + movie + syncFrame("DONE", size: 0))
    } else if command.contains("kill -INT") {
      if behavior != .finalization { lock.withLock { recordings[device]?.close() } }
    } else if command.contains("rm -f") {
      lock.withLock { removed.append(device) }
      if behavior == .cleanup { return }
    } else if command.contains("settings get") {
      try peer.writeLine("0")
    } else if command.contains("settings put system show_touches 0"), behavior == .settingsRestore {
      return
    } else if command.contains("wm density") || command.contains("ro.sf.lcd_density") {
      if behavior == .density { return }
      try peer.writeLine("160")
    } else if command.contains("dumpsys window displays") {
      try peer.writeLine("cur=16x16")
    }
    peer.close()
  }

  private func syncFrame(_ id: String, size: Int) -> Data {
    var length = UInt32(size).littleEndian
    return Data(id.utf8) + withUnsafeBytes(of: &length) { Data($0) }
  }

  private func readRequest(_ peer: ADBSocketConnection) throws -> String {
    let header = try read(peer, count: 4)
    guard let string = String(data: header, encoding: .ascii), let size = Int(string, radix: 16) else {
      throw ADBError.parseFailure("Invalid test request")
    }
    return try String(decoding: read(peer, count: size), as: UTF8.self)
  }

  private func read(_ peer: ADBSocketConnection, count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
      guard let chunk = try peer.readChunk(maxLength: count - data.count) else {
        throw ADBError.protocolFailure("Test connection closed")
      }
      data.append(chunk)
    }
    return data
  }
}
