import Testing

struct EmulatorConnectionTests {
  @Test("A reused serial does not inherit the old transport's boot result")
  func ignoresBootResultAfterTransportReuse() {
    let checked = [EmulatorConnection(serial: "emulator-5554", transportID: "2", state: .running)]
    let current = [EmulatorConnection(serial: "emulator-5554", transportID: "4", state: .starting)]

    #expect(EmulatorConnection.reconcileBootChecks(checked, current: current) == current)
  }

  @Test("A boot result applies to the same connected transport")
  func keepsBootResultForCurrentTransport() {
    let checked = [EmulatorConnection(serial: "emulator-5554", transportID: "2", state: .running)]
    let current = [EmulatorConnection(serial: "emulator-5554", transportID: "2", state: .starting)]

    #expect(EmulatorConnection.reconcileBootChecks(checked, current: current) == checked)
  }

  @Test("A boot result cannot bring back a disconnected emulator")
  func keepsCurrentOfflineState() {
    let checked = [EmulatorConnection(serial: "emulator-5554", transportID: "2", state: .running)]
    let current = [EmulatorConnection(serial: "emulator-5554", transportID: "2", state: .offline)]

    #expect(EmulatorConnection.reconcileBootChecks(checked, current: current) == current)
    #expect(EmulatorConnection.reconcileBootChecks(checked, current: []) == [])
  }
}
