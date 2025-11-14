import Combine
import Sparkle
import SwiftUI

@Observable
final class CheckForUpdatesViewModel {
  @ObservationIgnored private var bag = Set<AnyCancellable>()
  var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: \.canCheckForUpdates, on: self)
      .store(in: &bag)
  }
}

struct CheckForUpdatesView: View {
  @State private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    _viewModel = State(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    self.updater = updater
  }

  var body: some View {
    Button("Check for Updates…", action: updater.checkForUpdates)
      .disabled(!viewModel.canCheckForUpdates)
  }
}
