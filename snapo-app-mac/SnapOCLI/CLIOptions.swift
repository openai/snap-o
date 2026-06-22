import Foundation

struct DeviceSelectionOptions {
  var serialID: String?
  var useUSBDevice = false
  var useEmulator = false
}

struct CommonOptions {
  var selection = DeviceSelectionOptions()
  var json = false
}

struct NetworkListOptions {
  var common = CommonOptions()
  var includeAppInfo = true
}

struct NetworkRequestsOptions {
  var common = CommonOptions()
  var socketName: String?
  var noStream = false
  var filter = ""
}

struct NetworkShowOptions {
  var common = CommonOptions()
  var socketName: String?
  var requestID: String?
}

enum CLIOptionParser {
  static func parseList(_ arguments: [String]) throws -> NetworkListOptions {
    var options = NetworkListOptions()
    try parse(arguments) { argument, value in
      switch argument {
      case "--json":
        options.common.json = true
      case "--no-app-info":
        options.includeAppInfo = false
      default:
        if try parseSelection(argument, value: value, into: &options.common.selection) { return }
        throw CLIError.unknownOption(argument)
      }
    }
    return options
  }

  static func parseRequests(_ arguments: [String]) throws -> NetworkRequestsOptions {
    var options = NetworkRequestsOptions()
    try parse(arguments) { argument, value in
      switch argument {
      case "--json":
        options.common.json = true
      case "--no-stream":
        options.noStream = true
      case "-n", "--socket":
        options.socketName = try requireValue(value, for: argument)
      case "--filter":
        options.filter = try requireValue(value, for: argument)
      default:
        if try parseSelection(argument, value: value, into: &options.common.selection) { return }
        throw CLIError.unknownOption(argument)
      }
    }
    return options
  }

  static func parseShow(_ arguments: [String]) throws -> NetworkShowOptions {
    var options = NetworkShowOptions()
    try parse(arguments) { argument, value in
      switch argument {
      case "--json":
        options.common.json = true
      case "-n", "--socket":
        options.socketName = try requireValue(value, for: argument)
      case "-r", "--request-id":
        options.requestID = try requireValue(value, for: argument)
      default:
        if try parseSelection(argument, value: value, into: &options.common.selection) { return }
        throw CLIError.unknownOption(argument)
      }
    }
    return options
  }

  private static func parse(
    _ arguments: [String],
    consume: (String, String?) throws -> Void
  ) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      let takesValue = ["-s", "--serial", "-n", "--socket", "-r", "--request-id", "--filter"]
        .contains(argument)
      let value = takesValue && index + 1 < arguments.count ? arguments[index + 1] : nil
      try consume(argument, value)
      if takesValue {
        _ = try requireValue(value, for: argument)
        index += 1
      }
      index += 1
    }
  }

  private static func parseSelection(
    _ argument: String,
    value: String?,
    into selection: inout DeviceSelectionOptions
  ) throws -> Bool {
    switch argument {
    case "-s", "--serial":
      selection.serialID = try requireValue(value, for: argument)
      return true
    case "-d":
      selection.useUSBDevice = true
      return true
    case "-e":
      selection.useEmulator = true
      return true
    default:
      return false
    }
  }

  private static func requireValue(_ value: String?, for option: String) throws -> String {
    guard let value, !isRecognizedOption(value) else {
      throw CLIError.missingOptionValue(option)
    }
    return value
  }

  private static func isRecognizedOption(_ value: String) -> Bool {
    value.hasPrefix("--") || ["-d", "-e", "-s", "-n", "-r"].contains(value)
  }
}

enum CLIError: LocalizedError {
  case missingOptionValue(String)
  case unknownOption(String)

  var errorDescription: String? {
    switch self {
    case .missingOptionValue(let option):
      "Missing value for \(option)"
    case .unknownOption(let option):
      "Unknown option '\(option)'"
    }
  }
}
