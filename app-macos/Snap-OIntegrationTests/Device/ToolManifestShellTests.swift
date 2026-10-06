import Foundation
@testable import Snap_O
import Testing

struct ToolManifestShellTests {
  @Test("removes the reader after successful and failed invocations")
  func cleansUpManifestReader() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "snapo-reader-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let helper = Data("fixture reader".utf8)
    let command = try ToolManifestReader.metadataCommand(helper: helper, processIDs: [42])
      .replacingOccurrences(of: "/data/local/tmp", with: directory.path)
    // Capture the file the runtime would open without requiring Android in the unit test.
    for status: Int32 in [0, 7] {
      let script = "app_process() { cat \"$CLASSPATH\"; return \(status); };\n" + command
      let process = Process()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-c", script]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      let bytes = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == status)
      #expect(bytes == helper)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
  }

  @Test("overlapping readers execute their own helper even after another reader exits")
  func isolatesManifestReaders() throws {
    struct Reader {
      let process: Process
      let input: Pipe
      let output: Pipe
      let helper: Data
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: "snapo-readers-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var readers: [Reader] = []
    defer {
      for reader in readers where reader.process.isRunning {
        reader.process.terminate()
        reader.process.waitUntilExit()
      }
    }
    for name in ["first reader", "second reader"] {
      let helper = Data(name.utf8)
      let command = try ToolManifestReader.metadataCommand(helper: helper, processIDs: [42])
        .replacingOccurrences(of: "/data/local/tmp", with: directory.path)
      // Hold both runtimes after upload. The timeout bounds a failed test.
      let script = "app_process() { printf 'ready\\n'; read -r -t 5 proceed || return 1; cat \"$CLASSPATH\"; };\n" + command
      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = URL(filePath: "/bin/sh")
      process.arguments = ["-c", script]
      process.standardInput = input
      process.standardOutput = output
      try process.run()
      readers.append(Reader(process: process, input: input, output: output, helper: helper))
      try #require(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
    }
    for reader in readers.reversed() {
      try reader.input.fileHandleForWriting.write(contentsOf: Data("continue\n".utf8))
      let bytes = reader.output.fileHandleForReading.readDataToEndOfFile()
      reader.process.waitUntilExit()
      #expect(reader.process.terminationStatus == 0)
      #expect(bytes == reader.helper)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }
}
