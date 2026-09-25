import Foundation
@testable import Snap_O
import Testing

struct ToolHTTPRequestInputTests {
  @Test
  func getPreservesPathQueryAndHeaders() throws {
    var request = URLRequest(url: ToolURL.api.appending(path: "items").appending(queryItems: [.init(name: "page", value: "2")]))
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let input = try ToolHTTPRequestInput(request: request)
    #expect(input.head.method.rawValue == "GET")
    #expect(input.head.uri == "/items?page=2")
    #expect(input.head.headers.first(name: "Accept") == "application/json")
    #expect(input.head.headers.first(name: "Host") == "localhost")
    #expect(input.head.headers.first(name: "Origin") == "snapo://tool")
    #expect(input.body.isEmpty)
  }

  @Test(arguments: [false, true])
  func postReadsBodyAndReplacesTransportHeaders(streamed: Bool) throws {
    let body = Data(#"{"enabled":true}"#.utf8)
    var request = URLRequest(url: ToolURL.api.appending(path: "items"))
    request.httpMethod = "POST"
    if streamed {
      request.httpBodyStream = InputStream(data: body)
    } else {
      request.httpBody = body
    }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for name in ["Host", "Origin", "Content-Length", "Connection", "Transfer-Encoding"] {
      request.setValue("ignored", forHTTPHeaderField: name)
    }
    let input = try ToolHTTPRequestInput(request: request)
    #expect(input.head.method.rawValue == "POST")
    #expect(input.head.uri == "/items")
    #expect(input.head.headers.first(name: "Content-Type") == "application/json")
    #expect(input.head.headers.first(name: "Content-Length") == String(body.count))
    #expect(input.head.headers.first(name: "Host") == "localhost")
    #expect(input.head.headers.first(name: "Origin") == "snapo://tool")
    #expect(input.head.headers.first(name: "Connection") == "close")
    #expect(input.head.headers.first(name: "Transfer-Encoding") == nil)
    #expect(input.body == body)
  }
}
