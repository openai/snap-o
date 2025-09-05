import Combine
import Sparkle
import SwiftUI

final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: &$canCheckForUpdates)
  }
}

struct CheckForUpdatesView: View {
  @StateObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self._viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    self.updater = updater
  }

  var body: some View {
    Button("Check for Updates…", action: updater.checkForUpdates)
      .disabled(!viewModel.canCheckForUpdates)
  }
}
