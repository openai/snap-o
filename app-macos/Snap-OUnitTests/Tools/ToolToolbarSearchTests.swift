import Testing

@MainActor
struct ToolToolbarSearchTests {
  @Test
  func reconnectUsesTheFrontendClearAfterItAcknowledgesInput() {
    var search = ToolToolbarSearch(restoring: nil)
    let typed = toolbar("models", inputRevision: 1)
    search.value = "models"
    var stale = toolbar("", revision: 2)
    _ = search.reconcile(&stale, previous: typed)
    #expect(stale.actions.first?.value == "models")

    var cleared = toolbar("", revision: 3, inputRevision: 1)
    _ = search.reconcile(&cleared, previous: stale)
    var nextPage = ToolToolbarSearch(restoring: search.value)
    var replacement = toolbar("default")
    let event = nextPage.reconcile(&replacement, previous: ToolToolbar(revision: 0, actions: []))
    #expect(replacement.actions.first?.value == "")
    #expect(event?.value == "")
  }

  private func toolbar(_ value: String, revision: Int = 1, inputRevision: Int = 0) -> ToolToolbar {
    ToolToolbar(revision: revision, actions: [
      ToolToolbarAction(
        placement: nil, type: .search, id: "search", icon: nil, label: "Filter",
        enabled: true, value: value, inputRevision: inputRevision
      )
    ])
  }
}
