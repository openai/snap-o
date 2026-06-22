import Foundation

struct RequestDetailsLine: Encodable {
  let server: String
  let requestId: String
  let requestMethod: String?
  let requestUrl: String?
  let requestHeaders: [String: String]
  let requestBodyEncoding: String?
  let requestBody: String?
  let responseStatus: Int?
  let responseUrl: String?
  let responseHeaders: [String: String]
  let responseBody: String
  let responseBodyBase64Encoded: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(server, forKey: .server)
    try container.encode(requestId, forKey: .requestId)
    try container.encode(requestMethod, forKey: .requestMethod)
    try container.encode(requestUrl, forKey: .requestUrl)
    try container.encode(requestHeaders, forKey: .requestHeaders)
    try container.encode(requestBodyEncoding, forKey: .requestBodyEncoding)
    try container.encode(requestBody, forKey: .requestBody)
    try container.encode(responseStatus, forKey: .responseStatus)
    try container.encode(responseUrl, forKey: .responseUrl)
    try container.encode(responseHeaders, forKey: .responseHeaders)
    try container.encode(responseBody, forKey: .responseBody)
    try container.encode(responseBodyBase64Encoded, forKey: .responseBodyBase64Encoded)
  }

  private enum CodingKeys: String, CodingKey {
    case server
    case requestId
    case requestMethod
    case requestUrl
    case requestHeaders
    case requestBodyEncoding
    case requestBody
    case responseStatus
    case responseUrl
    case responseHeaders
    case responseBody
    case responseBodyBase64Encoded
  }
}

enum RequestDetailsResult {
  case success(RequestDetailsLine)
  case missingBody(String)
  case failure(String)
}

private struct RequestDetailsSnapshot {
  var requestSeen = false
  var requestHasPostData = false
  var requestMethod: String?
  var requestURL: String?
  var requestHeaders: [String: String] = [:]
  var requestBodyEncoding: String?
  var responseSeen = false
  var responseTerminal = false
  var loadingFailedMessage: String?
  var responseStatus: Int?
  var responseURL: String?
  var responseHeaders: [String: String] = [:]
}

struct RequestDetailsFetcher {
  private static let attemptLimit = 3

  let server: CLIServerReference
  let requestID: String

  func fetch() async -> RequestDetailsResult {
    guard let session = try? CLISession.open(server) else {
      return .failure("Failed to connect to \(server.identifier)")
    }

    do {
      try session.startStream()
      let result = try await fetch(using: session)
      await session.close()
      return result
    } catch {
      await session.close()
      return .failure(error.localizedDescription)
    }
  }

  private func fetch(using session: CLISession) async throws -> RequestDetailsResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    var details = RequestDetailsSnapshot()
    var nextCommandID = 1
    var pendingRequestBodyID: Int?
    var pendingResponseBodyID: Int?
    var requestBodyAttempts = 0
    var responseBodyAttempts = 0
    var requestBody: String?
    var requestBodyEncoding: String?
    var requestBodyResolved = false
    var responseBody: String?
    var responseBodyBase64Encoded = false
    var responseBodyResolved = false

    while clock.now < deadline {
      let record = await session.nextRecord(timeout: .milliseconds(500))
      if record == nil {
        // Preserve the Electron CLI's retry behavior: a 500 ms quiet period expires the current command attempt. If slow
        // body reads become a problem, retain all outstanding command IDs and accept late replies instead of changing retries.
        pendingRequestBodyID = nil
        pendingResponseBodyID = nil
      } else if case .network(let message) = record {
        details.update(message, requestID: requestID)
        requestBodyEncoding = requestBodyEncoding ?? details.requestBodyEncoding

        if !requestBodyResolved, details.requestSeen, !details.requestHasPostData {
          requestBodyResolved = true
        }
        if !responseBodyResolved, details.responseSeen, details.responseTerminal, details.responseHasNoBody {
          responseBody = ""
          responseBodyResolved = true
        }
        if details.responseTerminal, !details.responseSeen {
          return .failure(
            details.loadingFailedMessage ?? "Request failed before receiving a response for \(requestID)"
          )
        }

        if let id = message.id, message.method == nil {
          if id == pendingRequestBodyID {
            pendingRequestBodyID = nil
            requestBody = message.result?["postData"]?.stringValue
            requestBodyResolved = true
          } else if id == pendingResponseBodyID {
            pendingResponseBodyID = nil
            if let error = message.error {
              if let failure = details.loadingFailedMessage, !failure.isEmpty {
                return .failure(failure)
              }
              if error.message.lowercased().contains("no response body captured") {
                return .missingBody(error.message)
              }
              return .failure(error.message)
            }
            guard let body = message.result?["body"]?.stringValue,
                  let encoded = message.result?["base64Encoded"]?.boolValue else {
              return .failure("Malformed response for Network.getResponseBody")
            }
            responseBody = body
            responseBodyBase64Encoded = encoded
            responseBodyResolved = true
          }
        }
      }

      if details.requestSeen,
         details.requestHasPostData,
         !requestBodyResolved,
         pendingRequestBodyID == nil,
         requestBodyAttempts < Self.attemptLimit {
        pendingRequestBodyID = nextCommandID
        requestBodyAttempts += 1
        try session.send(bodyCommand(id: nextCommandID, method: "Network.getRequestPostData"))
        nextCommandID += 1
      }

      if details.responseSeen,
         details.responseTerminal,
         !details.responseHasNoBody,
         !responseBodyResolved,
         pendingResponseBodyID == nil,
         responseBodyAttempts < Self.attemptLimit {
        pendingResponseBodyID = nextCommandID
        responseBodyAttempts += 1
        try session.send(bodyCommand(id: nextCommandID, method: "Network.getResponseBody"))
        nextCommandID += 1
      }

      if !requestBodyResolved,
         requestBodyAttempts >= Self.attemptLimit,
         pendingRequestBodyID == nil {
        requestBodyResolved = true
      }

      if !responseBodyResolved,
         responseBodyAttempts >= Self.attemptLimit,
         pendingResponseBodyID == nil {
        return .failure(
          "Timed out waiting for Network.getResponseBody for \(requestID) on \(server.identifier)"
        )
      }

      if requestBodyResolved, responseBodyResolved {
        return .success(
          RequestDetailsLine(
            server: server.identifier,
            requestId: requestID,
            requestMethod: details.requestMethod,
            requestUrl: details.requestURL,
            requestHeaders: details.requestHeaders,
            requestBodyEncoding: requestBodyEncoding ?? details.requestBodyEncoding,
            requestBody: requestBody,
            responseStatus: details.responseStatus,
            responseUrl: details.responseURL,
            responseHeaders: details.responseHeaders,
            responseBody: responseBody ?? "",
            responseBodyBase64Encoded: responseBodyBase64Encoded
          )
        )
      }
    }

    return .failure("Timed out waiting for network lifecycle for \(requestID) on \(server.identifier)")
  }

  private func bodyCommand(id: Int, method: String) -> NetworkCDPMessage {
    NetworkCDPMessage(
      id: id,
      method: method,
      params: ["requestId": .string(requestID)]
    )
  }
}

private extension RequestDetailsSnapshot {
  mutating func update(_ message: NetworkCDPMessage, requestID: String) {
    switch message.method {
    case "Network.requestWillBeSent" where string(at: "requestId", in: message.params) == requestID:
      requestSeen = true
      requestHasPostData = bool(at: "request.hasPostData", in: message.params) ?? false
      requestMethod = string(at: "request.method", in: message.params)
      requestURL = string(at: "request.url", in: message.params)
      requestHeaders = CLIOutput.redactRequestHeaders(headers(at: "request.headers", in: message.params))
      requestBodyEncoding = string(at: "request.postDataEncoding", in: message.params)
    case "Network.responseReceived" where string(at: "requestId", in: message.params) == requestID:
      responseSeen = true
      responseStatus = number(at: "response.status", in: message.params).map(Int.init)
      responseURL = string(at: "response.url", in: message.params)
      responseHeaders = CLIOutput.redactResponseHeaders(headers(at: "response.headers", in: message.params))
    case "Network.loadingFinished" where string(at: "requestId", in: message.params) == requestID:
      responseTerminal = true
      loadingFailedMessage = nil
    case "Network.loadingFailed" where string(at: "requestId", in: message.params) == requestID:
      responseTerminal = true
      loadingFailedMessage = string(at: "errorText", in: message.params) ?? string(at: "type", in: message.params)
    default:
      break
    }
  }

  var responseHasNoBody: Bool {
    if requestMethod?.uppercased() == "HEAD" { return true }
    guard let responseStatus else { return false }
    if 100 ... 199 ~= responseStatus { return true }
    if [204, 205, 304].contains(responseStatus) { return true }
    guard let contentLength = headerValue(responseHeaders, named: "Content-Length") else { return false }
    return Int(contentLength) == 0
  }
}
