import Foundation
import Observation
@testable import Snap_O
import Synchronization
import Testing

@MainActor
struct ToolHostObservationTests {
  @Test
  func toolbarAndConnectionUpdatesDoNotInvalidateMenuState() {
    let page = makePage()
    defer { page.container.stop() }
    let menuChanges = Mutex(0)
    withObservationTracking {
      _ = page.isReady
      _ = page.identity.storageIdentifier
      _ = page.identity.developmentURL
    } onChange: {
      menuChanges.withLock { $0 += 1 }
    }

    for revision in 1 ... 10 {
      page.toolbar = ToolToolbar(revision: revision, actions: [])
      page.connection.revision = revision
      page.error = "Synthetic load failure \(revision)"
    }
    #expect(menuChanges.withLock { $0 } == 0)

    page.isReady = true
    #expect(menuChanges.withLock { $0 } == 1)
  }

  @Test
  func toolbarChangesRemainObservable() {
    let page = makePage()
    defer { page.container.stop() }
    let toolbarChanges = Mutex(0)
    withObservationTracking {
      _ = page.toolbar.actions
    } onChange: {
      toolbarChanges.withLock { $0 += 1 }
    }

    page.isReady = true
    page.connection.connected = true
    #expect(toolbarChanges.withLock { $0 } == 0)

    page.toolbar.actions.append(ToolToolbarAction(
      placement: .start, type: .button, id: "clear", icon: .clear,
      label: "Clear", enabled: true, value: nil, inputRevision: nil
    ))
    #expect(toolbarChanges.withLock { $0 } == 1)
    #expect(page.toolbar.actions.map(\.id) == ["clear"])
  }

  private func makePage() -> ToolHostModel.Page {
    ToolHostModel.Page(
      identity: ToolHostModel.PageIdentity(
        appID: nil, server: nil, processIdentity: nil, storageIdentifier: UUID(),
        packageRevision: nil, frontend: nil, developmentURL: nil, compatibility: .unknown
      ),
      container: ToolWebContainer(bridge: ToolWebBridge(), storageIdentifier: nil)
    )
  }
}
