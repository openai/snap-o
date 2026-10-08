import AVFoundation
import Foundation
import Testing

@MainActor
struct SnapOCommandCoordinatorTests {
  @Test(arguments: [false, true])
  func incomingLinksCannotReplaceAnApproval(approved: Bool) async throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.register(target)
    let original = try #require(URL(string: "snapo://open?serial=phone&server=test-host"))
    let other = try #require(URL(string: "snapo://open?serial=other"))
    let preview = try #require(URL(string: "snapo://open"))
    coordinator.authorizeDeviceLink = { request in
      #expect(request == .serial("phone", server: .ssh(destination: "test-host")))
      #expect(coordinator.handle(url: other))
      #expect(coordinator.handle(url: preview))
      coordinator.openDevice(.serial("internal-choice"))
      #expect(target.requests.isEmpty && target.previews == 0)
      return approved ? request : nil
    }
    #expect(coordinator.handle(url: original))
    await coordinator.deviceLinkTask?.value
    #expect(target.requests == (approved ? [.serial("phone", server: .ssh(destination: "test-host"))] : []))
    #expect(coordinator.deviceLinkTask == nil)
  }

  @Test(arguments: [false, true], ["", "&server=test-host"])
  func ordinaryLinksDoNotEnterApprovalQueue(windowExists: Bool, serverQuery: String) throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    let authorization = DeviceLinkAuthorization(
      servers: { [.remote(UUID()): DeviceLinkConnection(server: .ssh(destination: "test-host"))] },
      confirmEnable: { _, _ in Issue.record("Unexpected confirmation"); return false },
      enable: { _, _ in Issue.record("Unexpected enable") }
    )
    coordinator.requiresDeviceLinkApproval = authorization.requiresApproval
    coordinator.authorizeDeviceLink = { _ in Issue.record("Ordinary links must not wait for approval"); return nil }
    if windowExists { coordinator.register(target) }
    for serial in ["first", "second"] {
      let url = try #require(URL(string: "snapo://open?serial=\(serial)\(serverQuery)"))
      #expect(coordinator.handle(url: url))
      #expect(coordinator.deviceLinkTask == nil)
    }
    if !windowExists { coordinator.register(target) }
    let server: DeviceLinkServer = serverQuery.isEmpty ? .local() : .ssh(destination: "test-host")
    let serials = windowExists ? ["first", "second"] : ["second"]
    #expect(target.requests == serials.map { .serial($0, server: server) })
  }

  @Test(arguments: ["snapo://open", "snapo://open/", "SNAPO://OPEN"])
  func opensPreviewInAnInactiveWindow(address: String) throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.register(target)
    let url = try #require(URL(string: address))
    #expect(coordinator.handle(url: url))
    #expect(target.previews == 1)
  }

  @Test
  func queuesLatestRequestUntilWindowRegisters() throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    for name in ["First", "First", "Second"] {
      let url = try #require(URL(string: "snapo://open?avd=\(name)&start=true"))
      #expect(coordinator.handle(url: url))
    }
    #expect(windowsOpened == 1)
    let target = CommandTarget()
    coordinator.activate(target)
    #expect(target.requests == [.avd("Second", start: true)])
    coordinator.activate(target)
    #expect(target.requests.count == 1)
  }

  @Test(arguments: [true, false])
  func newestChoiceWinsAcrossEntryPoints(urlFirst: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    let urlRequest = DeviceOpenRequest.avd("Pixel", start: true)
    let deviceManagerRequest = DeviceOpenRequest.serial("phone")
    let url = try #require(URL(string: "snapo://open?avd=Pixel&start=true"))
    if urlFirst {
      #expect(coordinator.handle(url: url))
      coordinator.openDevice(deviceManagerRequest)
    } else {
      coordinator.openDevice(deviceManagerRequest)
      #expect(coordinator.handle(url: url))
    }
    let target = CommandTarget()
    coordinator.activate(target)
    #expect(target.requests == [urlFirst ? deviceManagerRequest : urlRequest])
  }

  @Test(arguments: [false, true])
  func repeatedDeviceLinksReuseCurrentWorkspace(appIsInactive: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    let other = CommandTarget()
    let current = CommandTarget()
    coordinator.register(other)
    coordinator.activate(current)
    if appIsInactive { coordinator.deactivate(current) }

    for serial in ["phone", "phone", "second-phone"] {
      let url = try #require(URL(string: "snapo://open?serial=\(serial)"))
      #expect(coordinator.handle(url: url))
    }

    #expect(windowsOpened == 0)
    #expect(other.requests.isEmpty)
    #expect(current.requests == [.serial("phone"), .serial("phone"), .serial("second-phone")])
  }

  @Test
  func routesToLastWorkspaceWhenAnotherWindowIsFocused() throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.activate(target)
    coordinator.deactivate(target)
    let url = try #require(URL(string: "snapo://open?serial=phone"))
    #expect(coordinator.handle(url: url))
    #expect(target.requests == [.serial("phone")])
    coordinator.openDevice(.serial("second-phone"))
    #expect(target.requests == [.serial("phone"), .serial("second-phone")])
  }

  @Test
  func coldLaunchRetainsRequest() throws {
    let coordinator = SnapOCommandCoordinator()
    let url = try #require(URL(string: "snapo://open?serial=phone"))
    #expect(coordinator.handle(url: url))
    let target = CommandTarget()
    coordinator.activate(target)
    #expect(target.requests == [.serial("phone")])
  }

  @Test
  func doesNotDispatchInvalidOpenRequest() throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.activate(target)
    let url = try #require(URL(string: "snapo://open?serial=phone&command=record"))
    #expect(!coordinator.handle(url: url))
    #expect(target.requests.isEmpty)
    #expect(target.previews == 0)
  }

  @Test(arguments: [false, true])
  func livePreviewUsesCurrentWorkspace(appIsInactive: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    let other = CommandTarget()
    let current = CommandTarget()
    coordinator.register(other)
    coordinator.activate(current)
    if appIsInactive { coordinator.deactivate(current) }

    let url = try #require(URL(string: "snapo://open"))
    #expect(coordinator.handle(url: url))
    #expect(current.previews == 1)
    #expect(other.previews == 0)
    #expect(windowsOpened == 0)
  }

  @Test(arguments: [false, true], [false, true])
  func repeatedLivePreviewRequestsOpenOneWorkspace(launcherIsReady: Bool, becomesKeyFirst: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    let openWorkspace = { windowsOpened += 1 }
    if launcherIsReady { coordinator.openWorkspace = openWorkspace }
    #expect(try coordinator.handle(url: #require(URL(string: "snapo://open"))))
    #expect(try coordinator.handle(url: #require(URL(string: "snapo://open"))))
    if !launcherIsReady { coordinator.openWorkspace = openWorkspace }
    #expect(windowsOpened == 1)

    let target = CommandTarget()
    if becomesKeyFirst { coordinator.activate(target) } else { coordinator.register(target) }
    #expect(target.previews == 1)
    coordinator.activate(target)
    #expect(target.previews == 1)
    #expect(windowsOpened == 1)
  }

  @Test(arguments: ["capture", "record", "recording", "livepreview"], [false, true])
  func removedURLsDoNotOpenOrChangeAWindow(command: String, registered: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    let target = CommandTarget()
    if registered { coordinator.register(target) }
    for address in ["snapo://\(command)", "snapo:///\(command)"] {
      #expect(try !coordinator.handle(url: #require(URL(string: address))))
    }
    coordinator.activate(target)
    #expect(windowsOpened == 0)
    #expect(target.previews == 0 && target.requests.isEmpty)
  }

  @Test(arguments: [
    "snapo://open?serial=", "snapo://open?avd=", "snapo://open?start=true",
    "snapo://open?unknown=value", "snapo://open#fragment", "snapo://open/extra",
    "snapo://user@open", "snapo://open:1234", "https://open"
  ])
  func invalidOpenDoesNotFallBackToCurrentPreview(address: String) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    #expect(try !coordinator.handle(url: #require(URL(string: address))))
    let target = CommandTarget()
    coordinator.register(target)
    #expect(windowsOpened == 0 && target.previews == 0 && target.requests.isEmpty)
  }

  @Test
  func thumbnailsBelongToOneConnection() {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    let original = DeviceTarget(serial: "phone", transportID: "1")
    let replacement = DeviceTarget(serial: "phone", transportID: "1")
    let renderer = AVSampleBufferVideoRenderer()
    let thumbnail = LivePreviewThumbnail()
    thumbnail.videoRenderer = renderer
    target.thumbnail = thumbnail
    target.connection = original
    coordinator.register(target)
    #expect(coordinator.liveThumbnail(for: original) === thumbnail)
    #expect(coordinator.liveThumbnail(for: replacement) == nil)
    original.invalidate()
    #expect(coordinator.liveThumbnail(for: original) == nil)
    target.connection = replacement
    #expect(coordinator.liveThumbnail(for: replacement) === thumbnail)
  }
}

@MainActor
private final class CommandTarget: SnapOCommandTarget {
  var requests: [DeviceOpenRequest] = []
  var previews = 0
  var connection: DeviceTarget?
  var thumbnail: LivePreviewThumbnail?

  func showLivePreview() {
    previews += 1
  }

  func openDevice(_ request: DeviceOpenRequest) {
    requests.append(request)
  }

  func liveThumbnail(for connection: DeviceTarget) -> LivePreviewThumbnail? {
    self.connection == connection ? thumbnail : nil
  }
}
