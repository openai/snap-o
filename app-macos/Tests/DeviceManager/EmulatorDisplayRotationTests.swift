import Foundation

func runDisplayRotationTests() throws {
  for current in 0 ..< 4 {
    for turns in [1, 3] {
      var commands: [[String]] = []
      var reads = 0
      let target = (current + turns) % 4
      try EmulatorDisplayRotation { arguments in
        commands.append(arguments)
        if arguments == ["dumpsys", "input"] {
          reads += 1
          let value = reads == 1 ? current : target
          return """
          Viewport INTERNAL: displayId=3, orientation=2, logicalFrame=[0, 0, 100, 200]
          Viewport INTERNAL: displayId=0, orientation=\(value), logicalFrame=[0, 0, 1080, 2400]
          """
        }
        return ""
      }.rotate(quarterTurns: turns)
      try expect(commands == [
        ["dumpsys", "input"],
        ["cmd", "window", "fixed-to-user-rotation", "enabled"],
        ["cmd", "window", "user-rotation", "lock", String(target)],
        ["dumpsys", "input"]
      ], "Rotate relative to the current main display, override app locks, and verify completion")
    }
  }

  var unreadableCommands = 0
  try expectFailure("Could not determine") {
    try EmulatorDisplayRotation { _ in
      unreadableCommands += 1
      return "Viewport INTERNAL: displayId=3, orientation=1"
    }.rotate(quarterTurns: 1)
  }
  try expect(unreadableCommands == 1, "An unreadable main display must not change rotation settings")

  try expectFailure("Android could not change") {
    try EmulatorDisplayRotation { arguments in
      arguments == ["dumpsys", "input"] ? "Viewport INTERNAL: displayId=0, orientation=0" : "Error: unsupported"
    }.rotate(quarterTurns: 1)
  }
}
