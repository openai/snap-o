import Darwin
import Foundation

@main
struct SnapOCLI {
  static func main() async {
    let exitCode = await CLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
    Darwin.exit(Int32(exitCode))
  }
}
