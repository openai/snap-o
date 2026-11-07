import Foundation
import Testing

struct DeviceOpenRequestTests {
  @Test(arguments: [
    ("snapo://open?serial=emulator-5554", DeviceOpenRequest.serial("emulator-5554")),
    ("snapo://open?serial=192.0.2.1:5555", .serial("192.0.2.1:5555")),
    ("snapo://open?serial=phone&adb_port=5038", .serial("phone", server: .local(adbPort: 5038))),
    (
      "snapo://open?serial=phone&server=user%40test-host&port=2222&adb_port=5038",
      .serial("phone", server: .ssh(destination: "user@test-host", port: 2222, adbPort: 5038))
    ),
    ("snapo://open?serial=phone&server=test-host", .serial("phone", server: .ssh(destination: "test-host"))),
    ("snapo://open?avd=Pixel_8_API_35&start=true", .avd("Pixel_8_API_35", start: true)),
    (
      "snapo://open?avd=Tablet%20%26%20Phone%20%2B%20%E6%97%A5%E6%9C%AC%E8%AA%9E&start=false",
      .avd("Tablet & Phone + 日本語", start: false)
    )
  ])
  func parsesLinks(address: String, request: DeviceOpenRequest) throws {
    let url = try #require(URL(string: address))
    #expect(DeviceOpenURL(url: url) == .target(request))
  }

  @Test(arguments: ["snapo://open", "snapo://open/", "SNAPO://OPEN", "snapo://open?"])
  func parsesCurrentPreview(address: String) throws {
    let url = try #require(URL(string: address))
    #expect(DeviceOpenURL(url: url) == .currentPreview)
  }

  @Test(arguments: ["", "&server=localhost", "&server=LOCALHOST&adb_port=5037"])
  func defaultsToLocalServer(parameters: String) throws {
    let url = try #require(URL(string: "snapo://open?serial=phone" + parameters))
    #expect(DeviceOpenURL(url: url) == .target(.serial("phone")))
  }

  @Test(arguments: ["port", "adb_port"], ["", "0", "65536", "-1", "+22", "22.0", "22%20", "ssh"])
  func rejectsInvalidPorts(parameter: String, value: String) throws {
    let url = try #require(URL(string: "snapo://open?serial=phone&server=test-host&\(parameter)=\(value)"))
    #expect(DeviceOpenURL(url: url) == nil)
  }

  @Test func preservesTargetCase() throws {
    let url = try #require(URL(string: "SNAPO://OPEN?avd=Pixel_8_API_35"))
    #expect(DeviceOpenURL(url: url) == .target(.avd("Pixel_8_API_35", start: false)))
  }

  @Test(arguments: [
    "https://open?serial=phone",
    "https://open",
    "snapo://open#fragment",
    "snapo://open/extra",
    "snapo://user@open",
    "snapo://open:1234",
    "snapo://open?unknown=value",
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
    "snapo://open?serial=phone#ignored",
    "snapo://open?serial=phone&server=",
    "snapo://open?serial=phone&server=-host",
    "snapo://open?serial=phone&server=test%20host",
    "snapo://open?serial=phone&server=test%00host",
    "snapo://open?serial=phone&server=one&server=two",
    "snapo://open?serial=phone&port=22",
    "snapo://open?serial=phone&server=localhost&port=22",
    "snapo://open?serial=phone&adb_port=5037&adb_port=5038",
    "snapo://open?serial=phone&server=test-host&port=22&port=23",
    "snapo://open?avd=Pixel&server=test-host",
    "snapo://open?avd=Pixel&port=22",
    "snapo://open?avd=Pixel&adb_port=5037"
  ])
  func rejectsInvalidLinks(text: String) throws {
    let url = try #require(URL(string: text))
    #expect(DeviceOpenURL(url: url) == nil)
  }

  @Test func rejectsExcessiveTargetLength() throws {
    let url = try #require(URL(string: "snapo://open?avd=" + String(repeating: "A", count: 513) + "&start=true"))
    #expect(DeviceOpenURL(url: url) == nil)
  }
}
