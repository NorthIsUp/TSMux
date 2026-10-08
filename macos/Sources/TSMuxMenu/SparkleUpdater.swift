import Sparkle
import TSMuxMenuKit

/// Started at launch rather than lazily: the updater has to be running to do
/// its own scheduled background checks, not only to answer the menu item.
@MainActor
final class SparkleUpdater: Updater {
  private let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
  func checkForUpdates() { controller.checkForUpdates(nil) }
}
