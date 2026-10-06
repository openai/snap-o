import Foundation
import Security

@main
struct PolicyTests {
  static func main() {
    // This test executable is deliberately not signed with a developer identity.
    precondition(AndroidHostAuthentication.clientRequirement() == nil)
    for (identifier, team): (String?, String?) in [
      (nil, "ABCDEFGHIJ"), ("com.example.app.AndroidHostService", nil),
      ("com.example.app.AndroidHostService", ""), ("com.example.app", "ABCDEFGHIJ"),
      (".AndroidHostService", "ABCDEFGHIJ"),
      ("com.example.\" or true //.AndroidHostService", "ABCDEFGHIJ"),
      ("com.example.app.AndroidHostService", "ABC\" or true")
    ] {
      precondition(AndroidHostAuthentication.clientRequirement(serviceIdentifier: identifier, teamIdentifier: team) == nil)
    }
    let text = AndroidHostAuthentication.clientRequirement(
      serviceIdentifier: "com.example.app.AndroidHostService", teamIdentifier: "ABCDEFGHIJ"
    )!
    var requirement: SecRequirement?
    precondition(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
    var code: SecStaticCode?
    precondition(SecStaticCodeCreateWithPath(URL(fileURLWithPath: CommandLine.arguments[0]) as CFURL, [], &code) == errSecSuccess)
    precondition(SecStaticCodeCheckValidity(code!, [], requirement) != errSecSuccess)
    print("Android host policy rejects missing identity, malformed identity, and ad-hoc signatures")
  }
}
