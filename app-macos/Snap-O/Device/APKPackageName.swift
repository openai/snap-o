import Foundation
import ZIPFoundation

enum APKPackageName {
  static func read(from url: URL) throws -> String? {
    let archive = try Archive(url: url, accessMode: .read)
    guard let entry = archive["AndroidManifest.xml"], entry.uncompressedSize <= 4 * 1024 * 1024 else { return nil }
    var data = Data()
    let checksum = try archive.extract(entry) { chunk in
      guard data.count + chunk.count <= 4 * 1024 * 1024 else {
        throw ADBError.parseFailure("The APK manifest is too large.")
      }
      data.append(chunk)
    }
    guard checksum == entry.checksum else { return nil }
    return parse(data)
  }

  /// APK manifests use Android's binary XML string pool and element records.
  static func parse(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    func uint16(_ offset: Int) -> Int? {
      guard offset >= 0, offset <= bytes.count - 2 else { return nil }
      return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }
    func uint32(_ offset: Int) -> Int? {
      guard let low = uint16(offset), let high = uint16(offset + 2) else { return nil }
      return low | high << 16
    }
    guard uint16(0) == 3, let size = uint32(4), size == bytes.count, let header = uint16(2), header >= 8 else { return nil }
    var strings: [String] = []
    var offset = header
    while offset <= size - 8 {
      guard let kind = uint16(offset), let headerSize = uint16(offset + 2), headerSize >= 8,
            let chunkSize = uint32(offset + 4), chunkSize >= headerSize, chunkSize <= size - offset
      else { return nil }
      let end = offset + chunkSize
      if kind == 1 {
        guard headerSize >= 28, let count = uint32(offset + 8), count <= (chunkSize - headerSize) / 4,
              let flags = uint32(offset + 16), let start = uint32(offset + 20), start >= headerSize + count * 4,
              start <= chunkSize else { return nil }
        let utf8 = flags & 0x100 != 0
        strings = []
        for index in 0 ..< count {
          guard let relative = uint32(offset + headerSize + index * 4), relative < chunkSize - start else { return nil }
          var cursor = offset + start + relative
          func length() -> Int? {
            if utf8 {
              guard cursor < end else { return nil }
              let first = Int(bytes[cursor])
              cursor += 1
              if first & 0x80 == 0 { return first }
              guard cursor < end else { return nil }
              let second = Int(bytes[cursor])
              cursor += 1
              return (first & 0x7F) << 8 | second
            }
            guard cursor <= end - 2, let first = uint16(cursor) else { return nil }
            cursor += 2
            if first & 0x8000 == 0 { return first }
            guard cursor <= end - 2, let second = uint16(cursor) else { return nil }
            cursor += 2
            return (first & 0x7FFF) << 16 | second
          }
          guard let characterCount = length(), let count = utf8 ? length() : characterCount else { return nil }
          let byteCount = count * (utf8 ? 1 : 2)
          guard byteCount <= end - cursor else { return nil }
          let encoded = Data(bytes[cursor ..< cursor + byteCount])
          guard let string = String(data: encoded, encoding: utf8 ? .utf8 : .utf16LittleEndian) else { return nil }
          strings.append(string)
        }
      } else if kind == 0x102 {
        let element = offset + headerSize
        guard element <= end - 20, let nameIndex = uint32(element + 4), strings.indices.contains(nameIndex) else { return nil }
        if strings[nameIndex] == "manifest" {
          guard let attributeStart = uint16(element + 8), attributeStart >= 20,
                let attributeSize = uint16(element + 10), attributeSize >= 20,
                let count = uint16(element + 12), attributeStart <= end - element,
                count <= (end - element - attributeStart) / attributeSize else { return nil }
          for index in 0 ..< count {
            let attribute = element + attributeStart + index * attributeSize
            guard let name = uint32(attribute + 4), strings.indices.contains(name) else { return nil }
            if strings[name] == "package", uint32(attribute) == 0xFFFF_FFFF {
              guard let raw = uint32(attribute + 8), let typed = uint32(attribute + 16) else { return nil }
              let value = raw == 0xFFFF_FFFF ? typed : raw
              guard raw != 0xFFFF_FFFF || bytes[attribute + 15] == 3,
                    strings.indices.contains(value) else { return nil }
              let package = strings[value]
              return package.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/) != nil ? package : nil
            }
          }
          return nil
        }
      }
      offset = end
    }
    return nil
  }
}
