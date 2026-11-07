enum CaptureReviewEscapeAction {
  case ignore
  case cancelTrim
  case confirmDiscard

  init(isNaming: Bool, isSaving: Bool, isClosing: Bool, hasError: Bool, isTrimming: Bool) {
    if isNaming || isSaving || isClosing || hasError {
      self = .ignore
    } else {
      self = isTrimming ? .cancelTrim : .confirmDiscard
    }
  }
}
