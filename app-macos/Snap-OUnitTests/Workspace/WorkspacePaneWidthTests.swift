import Testing

@MainActor
struct WorkspacePaneWidthTests {
  @Test
  func narrowTileFitsBothPanes() {
    let width = WorkspaceLayout.constrainedCapturePaneWidth(
      600, totalWidth: 401, aspectRatio: 2
    )
    #expect(width == 160)
  }

  @Test
  func widerTileHonorsThePreferredWidthAndToolMinimum() {
    #expect(WorkspaceLayout.constrainedCapturePaneWidth(
      600, totalWidth: 1441, aspectRatio: 2
    ) == 600)
    #expect(WorkspaceLayout.constrainedCapturePaneWidth(
      800, totalWidth: 1441, aspectRatio: 2
    ) == 720)
  }
}
