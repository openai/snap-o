import Foundation
import Security

enum AndroidHostAuthentication {
  static func clientRequirement() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let information = information as? [String: Any] else { return nil }
    return clientRequirement(
      serviceIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
      teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String
    )
  }

  static func clientRequirement(serviceIdentifier: String?, teamIdentifier: String?) -> String? {
    let suffix = ".AndroidHostService"
    let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    let teamCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    guard let serviceIdentifier, serviceIdentifier.hasSuffix(suffix),
          serviceIdentifier.unicodeScalars.allSatisfy(identifierCharacters.contains),
          let teamIdentifier, teamIdentifier.count == 10,
          teamIdentifier.unicodeScalars.allSatisfy(teamCharacters.contains) else { return nil }
    let appIdentifier = String(serviceIdentifier.dropLast(suffix.count))
    guard !appIdentifier.isEmpty else { return nil }
    // Trust our own signature, never the app directory that happens to contain us.
    // Release builds require an Apple developer identity.
    return "anchor apple generic and identifier \"\(appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
  }
}
