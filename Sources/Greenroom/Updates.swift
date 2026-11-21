import AppKit
import Sparkle

/// In-app updates (Sparkle 2). The only network request Greenroom makes on its own account: a GET of the appcast (the
/// list of versions) from GitHub, with no identifier and no system profile (PRIVACY.md). Nothing is checked until the
/// customer says yes: Sparkle asks on the second launch ("Check for updates automatically?"), Settings can change it,
/// and Check for Updates… asks once by hand. Updates are verified against the EdDSA key in Info.plist (SUPublicEDKey)
/// and the Developer ID signature before they are installed.
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private(set) var controller: SPUStandardUpdaterController?

    /// Starts the updater in the app, not in its command-line modes (smoke runs, checks), where a prompt or a check
    /// would be out of place. `--privacy-check` keeps it: that check is there to show it sends nothing unasked.
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let args = CommandLine.arguments
        let check = args.contains { $0.hasPrefix("--") && ($0.hasSuffix("-check") || $0.hasPrefix("--smoke")) }
        if check && !args.contains("--privacy-check") { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater? { controller?.updater }
    var available: Bool { updater != nil }

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }

    /// `GREENROOM_UPDATE_FEED`: another appcast, for testing an update end to end (scripts/update-check.sh). What it
    /// offers must still be signed with the key in Info.plist and by the same Developer ID.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["GREENROOM_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // Never send a system profile, whatever a feed or a default says.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}
