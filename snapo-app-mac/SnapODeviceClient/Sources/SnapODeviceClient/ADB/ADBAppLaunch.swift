import Foundation

public extension ADBClient {
  func openApp(deviceID: String, packageName: String) async throws {
    try await AppLaunchCommand.open(packageName: packageName) { command in
      try await runShellString(deviceID: deviceID, command: command)
    }
  }
}

enum AppLaunchCommand {
  private static let exitMarker = "SNAPO_APP_LAUNCH_EXIT:"

  static func open(packageName: String, runShell: (String) async throws -> String) async throws {
    let query = try launcherQuery(packageName: packageName)
    let output = try await runShell(query)
    let component = try launcherComponent(output: output, packageName: packageName)
    let command = try command(packageName: packageName, component: component)
    try await validate(output: runShell(command))
  }

  static func launcherQuery(packageName: String) throws -> String {
    guard isPackageName(packageName) else {
      throw ADBError.protocolFailure("The app's package name is unavailable or invalid.")
    }

    // Implicit starts require DEFAULT filters; launcher queries must not.
    return withExitStatus(
      "cmd package query-activities --components --query-flags 0 --user current "
        + "-a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p '\(packageName)'"
    )
  }

  static func launcherComponent(output: String, packageName: String) throws -> String {
    try validate(output: output)
    let components = output.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let component = components.first(where: { isComponent($0, inPackage: packageName) }) else {
      throw AppLaunchError.noLauncher(packageName)
    }
    return component
  }

  static func command(packageName: String, component: String) throws -> String {
    guard isComponent(component, inPackage: packageName) else {
      throw ADBError.protocolFailure("The app's launcher activity is invalid.")
    }

    // Match a launcher tap without stopping the app or clearing its task.
    return withExitStatus(
      "am start --user current -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "
        + "-n '\(component)' -f 0x10200000"
    )
  }

  static func validate(output: String) throws {
    let lines = output.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let lastLine = lines.last,
          lastLine.hasPrefix(exitMarker),
          let status = Int32(lastLine.dropFirst(exitMarker.count))
    else {
      throw ADBError.parseFailure("No app launch result was returned.")
    }

    if let error = lines.first(where: { $0.hasPrefix("Error:") }) {
      throw AppLaunchError.failed(String(error.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces))
    }
    let message = lines.dropLast().joined(separator: "\n")
    guard status == 0 else {
      throw ADBError.nonZeroExit(status, stderr: message)
    }
    // Some Android versions report activity errors with a successful shell exit.
    if let error = lines.first(where: { $0.hasPrefix("Error type ") }) {
      throw AppLaunchError.failed(error)
    }
  }

  private static func isComponent(_ component: String, inPackage packageName: String) -> Bool {
    let parts = component.split(separator: "/", omittingEmptySubsequences: false)
    guard isPackageName(packageName), parts.count == 2, parts[0] == packageName else {
      return false
    }
    return parts[1].wholeMatch(of: /\.?[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*/) != nil
  }

  private static func isPackageName(_ packageName: String) -> Bool {
    packageName.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+/) != nil
  }

  private static func withExitStatus(_ command: String) -> String {
    "\(command) 2>&1; printf '\\n\(exitMarker)%s\\n' \"$?\""
  }
}

enum AppLaunchError: LocalizedError {
  case noLauncher(String)
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .noLauncher(let packageName):
      "No launcher activity was found for \(packageName) on this device."
    case .failed(let message):
      message
    }
  }
}
