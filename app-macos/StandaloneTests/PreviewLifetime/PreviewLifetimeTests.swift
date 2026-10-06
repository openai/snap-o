import Darwin
import Testing

@main
struct PreviewLifetimeTests {
  static func main() async {
    let result: CInt = await Testing.__swiftPMEntryPoint()
    exit(result)
  }
}
