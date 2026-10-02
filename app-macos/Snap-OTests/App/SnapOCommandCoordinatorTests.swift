import Foundation
@testable import Snap_O
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

  func perform(_ command: SnapOCommand) {
    commands.append(command)
  }

  func openDevice(_ request: DeviceOpenRequest) {
    requests.append(request)
  }

  func liveThumbnail(deviceID: String) -> LivePreviewThumbnail? {
    nil
  }
}
