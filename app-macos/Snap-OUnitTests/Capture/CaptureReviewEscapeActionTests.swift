import Testing

struct CaptureReviewEscapeActionTests {
  @Test(arguments: [false, true])
  func escapeCancelsTrimmingBeforeOfferingToDiscard(isTrimming: Bool) {
    let action = CaptureReviewEscapeAction(
      isNaming: false, isSaving: false, isClosing: false, hasError: false, isTrimming: isTrimming
    )
    #expect(action == (isTrimming ? .cancelTrim : .confirmDiscard))
  }

  @Test(arguments: Blocker.allCases, [false, true])
  func escapeDoesNotInterruptAnotherAction(blocker: Blocker, isTrimming: Bool) {
    let action = CaptureReviewEscapeAction(
      isNaming: blocker == .naming, isSaving: blocker == .saving,
      isClosing: blocker == .closing, hasError: blocker == .error, isTrimming: isTrimming
    )
    #expect(action == .ignore)
  }

  enum Blocker: CaseIterable {
    case naming, saving, closing, error
  }
}
