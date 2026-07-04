import Foundation
import Sparkle

enum UpdateConfiguration {
    static let feedURL = URL(
        string: "https://github.com/Enoch-015/Audiobit/releases/download/latest-main/appcast.xml"
    )!
    static let publicEDKey = "gZ/Ep5WAyRIzdvT8m1qfGLwBH7ApCbcZ1FZS7l9etJk="
    static let checkInterval: TimeInterval = 86_400

    static func isConfigured(in bundle: Bundle = .main) -> Bool {
        bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
            == feedURL.absoluteString
            && bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
            == publicEDKey
    }
}

@MainActor
final class UpdateController: ObservableObject {
    let standardController: SPUStandardUpdaterController

    var updater: SPUUpdater {
        standardController.updater
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? {
        updater.lastUpdateCheckDate
    }

    var installedVersion: String {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(shortVersion) (\(build))"
    }

    init(startingUpdater: Bool = UpdateConfiguration.isConfigured()) {
        standardController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
