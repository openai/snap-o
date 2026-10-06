import AVFoundation
import Foundation
#if !SNAPO_STANDALONE_TESTS
@testable import Snap_O
#endif
import Testing

@MainActor
struct SnapOCommandCoordinatorTests {
  @Test func deliversColdLaunchCommandBeforeWindowBecomesKey() throws {
    let coordinator = SnapOCommandCoordinator()
    let url = try #require(URL(string: "snapo://capture"))
    #expect(coordinator.handle(url: url))
    let target = CommandTarget()
    coordinator.register(target)
    #expect(target.commands == [.capture])
    coordinator.activate(target)
    #expect(target.commands == [.capture])
  }

  @Test func deliversCommandsToAnInactiveWindow() throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.register(target)
    let url = try #require(URL(string: "snapo://record"))
    #expect(coordinator.handle(url: url))
    #expect(target.commands == [.record])
  }

  @Test func queuesLatestRequestUntilWindowRegisters() throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    for name in ["First", "First", "Second"] {
      let url = try #require(DeviceOpenRequest.avd(name, start: true).url)
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
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    let urlRequest = DeviceOpenRequest.avd("Pixel", start: true)
    let deviceManagerRequest = DeviceOpenRequest.serial("phone")
    let url = try #require(urlRequest.url)
    if urlFirst {
      #expect(coordinator.handle(url: url))
      coordinator.openDevice(deviceManagerRequest)
    } else {
      coordinator.openDevice(deviceManagerRequest)
      #expect(coordinator.handle(url: url))
    }
    #expect(windowsOpened == 1)
    let target = CommandTarget()
    coordinator.activate(target)
    #expect(target.requests == [urlFirst ? deviceManagerRequest : urlRequest])
    coordinator.activate(target)
    #expect(target.requests.count == 1)
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
      let url = try #require(DeviceOpenRequest.serial(serial).url)
      #expect(coordinator.handle(url: url))
    }

    #expect(windowsOpened == 0)
    #expect(other.requests.isEmpty)
    #expect(current.requests == [.serial("phone"), .serial("phone"), .serial("second-phone")])
  }

  @Test func routesToLastWorkspaceWhenAnotherWindowIsFocused() throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.activate(target)
    coordinator.deactivate(target)
    let url = try #require(DeviceOpenRequest.serial("phone").url)
    #expect(coordinator.handle(url: url))
    #expect(target.requests == [.serial("phone")])
    coordinator.openDevice(.serial("second-phone"))
    #expect(target.requests == [.serial("phone"), .serial("second-phone")])
  }

  @Test func coldLaunchRetainsRequest() throws {
    let coordinator = SnapOCommandCoordinator()
    let url = try #require(DeviceOpenRequest.serial("phone").url)
    #expect(coordinator.handle(url: url))
    let target = CommandTarget()
    coordinator.activate(target)
    #expect(target.requests == [.serial("phone")])
  }

  @Test func doesNotDispatchInvalidOpenRequest() throws {
    let coordinator = SnapOCommandCoordinator()
    let target = CommandTarget()
    coordinator.activate(target)
    let url = try #require(URL(string: "snapo://open?serial=phone&command=record"))
    #expect(!coordinator.handle(url: url))
    #expect(target.requests.isEmpty)
    #expect(target.commands.isEmpty)
  }

  @Test(arguments: [SnapOCommand.capture, .record, .livepreview], [false, true])
  func commandURLsUseCurrentWorkspace(command: SnapOCommand, appIsInactive: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    coordinator.openWorkspace = { windowsOpened += 1 }
    let other = CommandTarget()
    let current = CommandTarget()
    coordinator.register(other)
    coordinator.activate(current)
    if appIsInactive { coordinator.deactivate(current) }

    let url = try #require(URL(string: "snapo://\(command.rawValue)"))
    #expect(coordinator.handle(url: url))
    #expect(current.commands == [command])
    #expect(other.commands.isEmpty)
    #expect(windowsOpened == 0)
  }

  @Test(arguments: [false, true])
  func queuedCommandsOpenOneWorkspace(launcherIsReady: Bool) throws {
    let coordinator = SnapOCommandCoordinator()
    var windowsOpened = 0
    let openWorkspace = { windowsOpened += 1 }
    if launcherIsReady { coordinator.openWorkspace = openWorkspace }
    #expect(try coordinator.handle(url: #require(URL(string: "snapo://record"))))
    #expect(try coordinator.handle(url: #require(URL(string: "snapo://capture"))))
    if !launcherIsReady { coordinator.openWorkspace = openWorkspace }
    #expect(windowsOpened == 1)

    let target = CommandTarget()
    coordinator.register(target)
    coordinator.activate(target)
    #expect(target.commands == [.record, .capture])
    #expect(windowsOpened == 1)
  }

  @Test func thumbnailsBelongToOneConnection() {
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

  @Test func preservesExistingCommands() throws {
    let coordinator = SnapOCommandCoordinator()
    let url = try #require(URL(string: "snapo://capture"))
    #expect(coordinator.handle(url: url))
    let target = CommandTarget()
    coordinator.activate(target)
    #expect(target.commands == [.capture])
  }
}

@MainActor
private final class CommandTarget: SnapOCommandTarget {
  var requests: [DeviceOpenRequest] = []
  var commands: [SnapOCommand] = []
  var connection: DeviceTarget?
  var thumbnail: LivePreviewThumbnail?

  func perform(_ command: SnapOCommand) {
    commands.append(command)
  }

  func openDevice(_ request: DeviceOpenRequest) {
    requests.append(request)
  }

  func liveThumbnail(for connection: DeviceTarget) -> LivePreviewThumbnail? {
    self.connection == connection ? thumbnail : nil
  }
}
