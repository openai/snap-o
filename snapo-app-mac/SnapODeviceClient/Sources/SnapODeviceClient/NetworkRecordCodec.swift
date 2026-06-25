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

    switch message.method {
    case SnapONetworkProtocol.Method.appInfo:
      guard let params = message.params,
            let paramsData = try? JSONEncoder().encode(JSONValue.object(params)),
            let info = try? JSONDecoder().decode(NetworkAppInfo.self, from: paramsData)
      else {
        return .unknown
      }
      return .appInfo(info)

    case SnapONetworkProtocol.Method.replayComplete:
      return .replayComplete(watermark: watermark(in: message.params))

    case .some:
      return .network(message)

    case .none where message.id != nil:
      return .network(message)

    case .none:
      return .unknown
    }
  }

  private static func watermark(in params: [String: JSONValue]?) -> UInt64? {
    guard case .number(let value)? = params?["watermark"],
          value >= 0,
          value.rounded(.towardZero) == value
    else {
      return nil
    }
    return UInt64(exactly: value)
  }
}
