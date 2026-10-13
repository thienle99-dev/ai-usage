import AppKit
import Sparkle

@MainActor final class UpdateManager: ObservableObject {
    private let controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    init(bundle: Bundle = .main) {
        guard
            let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            URL(string: feedURL) != nil,
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !publicKey.isEmpty
        else {
            controller = nil
            return
        }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
