import Foundation
@testable import Snap_O
import Testing

struct DeviceOpenRequestTests {
  @Test(arguments: [
    DeviceOpenRequest.serial("emulator-5554"),
    .serial("192.0.2.1:5555"),
    .avd("Pixel_8_API_35", start: true),
    .avd("Tablet & Phone + 日本語", start: false)
  ])
  func roundTrips(request: DeviceOpenRequest) throws {
    let url = try #require(request.url)
    #expect(DeviceOpenRequest(url: url) == request)
  }

  @Test func preservesTargetCase() throws {
    let url = try #require(URL(string: "SNAPO://OPEN?avd=Pixel_8_API_35"))
    #expect(DeviceOpenRequest(url: url) == .avd("Pixel_8_API_35", start: false))
  }

  @Test(arguments: [
    "https://open?serial=phone",
    "snapo://open",
    "snapo://open?serial=",
    "snapo://open?serial",
    "snapo://open?avd=",
    "snapo://open?avd=Pixel&serial=phone",
    "snapo://open?avd=Pixel&avd=Other",
    "snapo://open?serial=phone&serial=phone",
    "snapo://open?avd=Pixel&start=true&start=false",
    "snapo://open?avd=Pixel&start",
    "snapo://open?avd=Pixel&start=1",
    "snapo://open?serial=phone&start=true",
    "snapo://open?serial=phone&start=false",
    "snapo://open?avd=Pixel&command=wipe",
    "snapo://open?avd=Pixel&path=/tmp/test",
    "snapo://open?avd=Pixel&callback=https://example.com",
    "snapo://open?avd=Pixel%00",
    "snapo://open?serial=phone%0A",
    "snapo://user@open?serial=phone",
    "snapo://open:1234?serial=phone",
    "snapo://open/extra?serial=phone",
    "snapo://open?serial=phone#ignored"
  ])
  func rejectsInvalidLinks(text: String) throws {
    let url = try #require(URL(string: text))
    #expect(DeviceOpenRequest(url: url) == nil)
  }

  @Test func rejectsExcessiveTargetLength() throws {
    let url = try #require(DeviceOpenRequest.avd(String(repeating: "A", count: 513), start: true).url)
    #expect(DeviceOpenRequest(url: url) == nil)
  }
}
