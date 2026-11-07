import Foundation
import Testing

struct ToolManifestShellTests {
  @Test
  func readerUploadAndCleanupUseAnInvocationLocalDirectory() throws {
    let helper = Data("fixture reader".utf8)
    let command = try ToolManifestReader.metadataCommand(helper: helper, processIDs: [42])
    let lines = command.components(separatedBy: "\n")
    #expect(lines.first == "directory=$(mktemp -d /data/local/tmp/snapo-discovery.XXXXXX) || exit 1")
    #expect(lines[1] == #"trap 'rm -f "$directory/reader.jar"; rmdir "$directory"' EXIT"#)
    #expect(command.contains(helper.base64EncodedString()))
    #expect(command.contains(#"base64 -d > "$directory/reader.jar""#))
    #expect(command.contains(#"CLASSPATH="$directory/reader.jar" app_process / com.openai.snapo.discovery.Main 42"#))
  }
}
