import CoreMedia
import Foundation

/// Mixes stereo PCM on the video timeline so every player hears both sources.
final class RecordingAudioMixer {
  enum Source { case device, computer }

  private let start: CMTime
  private let blockFrames: Int64 = 960
  private let channels = 2
  private var blocks: [Int64: [Int16]] = [:]
  private var deviceEnd: Int64 = 0
  private var computerEnd: Int64 = 0

  init(start: CMTime) {
    self.start = start
  }

  func receive(_ packet: DeviceAudioPacket, from source: Source, write: (DeviceAudioPacket) throws -> Void) throws {
    let first = CMTimeConvertScale(packet.timestamp - start, timescale: DeviceAudioPacket.sampleRate, method: .roundHalfAwayFromZero).value
    let end = first + Int64(packet.pcm.count / DeviceAudioPacket.bytesPerFrame)
    var frame = max(first, source == .device ? deviceEnd : computerEnd)
    guard frame < end else { return }
    packet.pcm.withUnsafeBytes { bytes in
      while frame < end {
        let blockStart = frame / blockFrames * blockFrames
        var block = blocks.removeValue(forKey: blockStart) ?? [Int16](repeating: 0, count: Int(blockFrames) * channels)
        let next = min(end, blockStart + blockFrames)
        let input = Int(frame - first) * channels
        let output = Int(frame - blockStart) * channels
        for index in 0 ..< Int(next - frame) * channels {
          let value = bytes.loadUnaligned(fromByteOffset: (input + index) * MemoryLayout<Int16>.size, as: Int16.self)
          block[output + index] = Int16(clamping: Int(block[output + index]) + Int(value))
        }
        blocks[blockStart] = block
        frame = next
      }
    }
    if source == .device { deviceEnd = end } else { computerEnd = end }
    // Each source delivers packets in order. Later packets cannot change a completed block.
    try drain(through: min(deviceEnd, computerEnd) / blockFrames * blockFrames, write: write)
    guard blocks.count <= 512 else { throw RecordingAudioError(errorDescription: "Recording waited too long for audio from both sources.") }
  }

  func finish(write: (DeviceAudioPacket) throws -> Void) throws {
    try drain(through: max(deviceEnd, computerEnd), write: write)
  }

  private func drain(through end: Int64, write: (DeviceAudioPacket) throws -> Void) throws {
    for frame in blocks.keys.sorted() where frame < end {
      guard let block = blocks.removeValue(forKey: frame) else { continue }
      let count = Int(min(blockFrames, end - frame)) * DeviceAudioPacket.bytesPerFrame
      let pcm = block.withUnsafeBytes { Data($0.prefix(count)) }
      try write(DeviceAudioPacket(timestamp: start + CMTime(value: frame, timescale: DeviceAudioPacket.sampleRate), pcm: pcm))
    }
  }
}
