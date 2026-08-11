import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var configurationError: String?

  private let controller: SPUStandardUpdaterController?

  init(bundle: Bundle = .main) {
    guard Self.isConfigured(bundle: bundle) else {
      controller = nil
      return
    }

    let controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    self.controller = controller
    do {
      try controller.updater.start()
      canCheckForUpdates = controller.updater.canCheckForUpdates
    } catch {
      configurationError = error.localizedDescription
    }
    controller.updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
    Task { @MainActor [weak self, weak controller] in
      await Task.yield()
      guard let self, let controller else { return }
      self.canCheckForUpdates = controller.updater.canCheckForUpdates
    }
  }

  func checkForUpdates() {
    controller?.updater.checkForUpdates()
  }

  private static func isConfigured(bundle: Bundle) -> Bool {
    guard
      let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      !publicKey.isEmpty,
      let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let url = URL(string: feed),
      url.scheme == "https" || (url.scheme == "http" && url.host == "localhost")
    else { return false }
    return true
  }
}
