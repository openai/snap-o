@testable import SnapODeviceClient
import Testing

@Suite("ADB app launch")
struct ADBAppLaunchTests {
  @Test("queries launcher activities without requiring a DEFAULT filter")
  func launcherQuery() throws {
    let query = try AppLaunchCommand.launcherQuery(packageName: "com.example.demo_app")
    #expect(query.contains("cmd package query-activities --components --query-flags 0 --user current"))
    #expect(query.contains("-a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p 'com.example.demo_app'"))
  }

  @Test("starts the explicit launcher without stopping or clearing the app")
  func launcherCommand() throws {
    let command = try AppLaunchCommand.command(packageName: "com.example.demo_app", component: "com.example.demo_app/.Launcher")
    #expect(command.contains("am start --user current -a android.intent.action.MAIN"))
    #expect(command.contains("-c android.intent.category.LAUNCHER -n 'com.example.demo_app/.Launcher' -f 0x10200000"))
    #expect(command.contains("2>&1; printf '\\nSNAPO_APP_LAUNCH_EXIT:%s\\n' \"$?\""))
    #expect(!command.contains("force-stop"))
    #expect(!command.contains(" -S"))
  }

  @Test("rejects placeholders, process names, and shell syntax", arguments: [
    "", "snapo_network_123", "com.example.demo:worker", "com.example.demo;id",
    "com.example.'demo'", "com.example.demo\n", "com.example.$(id)", "-p com.example.demo"
  ])
  func invalidPackage(packageName: String) {
    #expect(throws: ADBError.self) {
      try AppLaunchCommand.launcherQuery(packageName: packageName)
    }
  }

  @Test("accepts a new launch and an existing task brought to the foreground", arguments: [
    "Starting: Intent { act=android.intent.action.MAIN }\n",
    "Starting: Intent { act=android.intent.action.MAIN }\r\n"
      + "Warning: Activity not started, its current task has been brought to the front\r\n",
    "Warning: Activity not started, intent has been delivered to currently running top-most instance.\n"
  ])
  func successfulLaunch(output: String) throws {
    try AppLaunchCommand.validate(output: output + "\nSNAPO_APP_LAUNCH_EXIT:0\n")
  }

  @Test("reports activity errors even when the shell succeeds", arguments: [
    "Error: Activity not started, unable to resolve Intent\nSNAPO_APP_LAUNCH_EXIT:0\n",
    "Error type 3\nSNAPO_APP_LAUNCH_EXIT:0\n"
  ])
  func activityError(output: String) {
    #expect(throws: AppLaunchError.self) {
      try AppLaunchCommand.validate(output: output)
    }
  }

  @Test("uses a queried launcher alias instead of an implicit package intent")
  func resolvesBeforeLaunching() async throws {
    var commands: [String] = []
    try await AppLaunchCommand.open(packageName: "com.example.demo") { command in
      commands.append(command)
      if commands.count == 1 {
        return "com.example.demo/com.example.ui.LauncherAlias\nSNAPO_APP_LAUNCH_EXIT:0\n"
      }
      return "Starting: Intent\nSNAPO_APP_LAUNCH_EXIT:0\n"
    }
    #expect(commands.count == 2)
    #expect(commands[0].contains("query-activities --components --query-flags 0"))
    #expect(commands[1].contains("-n 'com.example.demo/com.example.ui.LauncherAlias'"))
    #expect(!commands[1].contains(" -p "))
  }

  @Test("accepts relative, full, and nested activity names", arguments: [
    "com.example.demo/.Launcher", "com.example.demo/com.example.ui.MainActivity",
    "com.example.demo/com.example.ui.MainActivity$Launcher"
  ])
  func componentNames(component: String) throws {
    let selected = try AppLaunchCommand.launcherComponent(
      output: "\(component)\r\nSNAPO_APP_LAUNCH_EXIT:0\r\n",
      packageName: "com.example.demo"
    )
    #expect(selected == component)
    let command = try AppLaunchCommand.command(packageName: "com.example.demo", component: selected)
    #expect(command.contains("-n '\(component)'"))
  }

  @Test("uses the first returned launcher for the selected package")
  func multipleLaunchers() throws {
    let component = try AppLaunchCommand.launcherComponent(
      output: "com.example.demo/.First\ncom.example.demo/.Second\nSNAPO_APP_LAUNCH_EXIT:0\n",
      packageName: "com.example.demo"
    )
    #expect(component == "com.example.demo/.First")
  }

  @Test("rejects foreign components and shell syntax", arguments: [
    "com.example.other/.Launcher", "com.example.demo/.Launcher;id", "com.example.demo/$(id)",
    "com.example.demo/.Launcher'", "com.example.demo/.Launcher\n", "com.example.demo/"
  ])
  func invalidComponent(component: String) {
    #expect(throws: ADBError.self) {
      try AppLaunchCommand.command(packageName: "com.example.demo", component: component)
    }
  }

  @Test("does not try to launch when no launcher activity exists")
  func missingLauncher() async {
    var commands: [String] = []
    await #expect {
      try await AppLaunchCommand.open(packageName: "com.example.demo") { command in
        commands.append(command)
        return "No activities found\nSNAPO_APP_LAUNCH_EXIT:0\n"
      }
    } throws: { error in
      guard case AppLaunchError.noLauncher("com.example.demo") = error else { return false }
      return true
    }
    #expect(commands.count == 1)
  }

  @Test("stops if launcher discovery fails")
  func failedQuery() async {
    var count = 0
    await #expect(throws: ADBError.self) {
      try await AppLaunchCommand.open(packageName: "com.example.demo") { _ in
        count += 1
        throw ADBError.serverUnavailable("Device disconnected")
      }
    }
    #expect(count == 1)
  }

  @Test("shows the activity error without the raw intent dump")
  func readableActivityError() {
    #expect {
      try AppLaunchCommand.validate(
        output: "Starting: Intent { act=android.intent.action.MAIN }\nError: Permission denied\nSNAPO_APP_LAUNCH_EXIT:1\n"
      )
    } throws: { error in
      guard case AppLaunchError.failed("Permission denied") = error else { return false }
      return true
    }
  }

  @Test("preserves command failures for the user")
  func failedLaunch() {
    #expect {
      try AppLaunchCommand.validate(output: "Permission denied\nSNAPO_APP_LAUNCH_EXIT:1\n")
    } throws: { error in
      guard case ADBError.nonZeroExit(1, stderr: "Permission denied") = error else { return false }
      return true
    }
  }

  @Test("does not mistake missing or malformed results for success", arguments: [
    "", "Starting: Intent", "SNAPO_APP_LAUNCH_EXIT:unknown", "SNAPO_APP_LAUNCH_EXIT:0\ntrailing data"
  ])
  func missingResult(output: String) {
    #expect(throws: ADBError.self) {
      try AppLaunchCommand.validate(output: output)
    }
  }
}
