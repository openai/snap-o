import Foundation

public enum NetworkRecordCodec {
  public static func encode(_ message: NetworkCDPMessage) throws -> String {
    let data = try JSONEncoder().encode(message)
    guard let line = String(data: data, encoding: .utf8) else {
      throw ADBError.protocolFailure("unable to encode Network Inspector message")
    }
    return line
  }

  public static func decode(_ line: String) -> NetworkServerRecord {
    guard let data = line.data(using: .utf8),
          let message = try? JSONDecoder().decode(NetworkCDPMessage.self, from: data)
    else {
      return .unknown
    }

    guard message.method?.hasPrefix("Network.") == true, message.params != nil,
          message.id == nil, message.result == nil, message.error == nil else {
      return .unknown
    }
    return .network(message)
  }
}
