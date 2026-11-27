import AppKit
import os
import Sparkle

/// In-app updates (Sparkle 2). The only network request Greenroom makes on its own account: a GET of the appcast (the
/// list of versions) from GitHub, with no identifier and no system profile (PRIVACY.md). Nothing is checked until the
/// customer says yes: Sparkle asks on the second launch ("Check for updates automatically?"), Settings can change it,
/// and Check for Updates… asks once by hand. An update is installed only if it is signed with the EdDSA key in
/// Info.plist (SUPublicEDKey) or by the same Developer ID (Sparkle accepts either).
final class Updates: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    static let shared = Updates()
    private static let log = Logger(subsystem: "io.github.aglose.greenroom", category: "updates")
    private(set) var controller: SPUStandardUpdaterController?

    /// Starts the updater in the app, not in its command-line modes (smoke runs, checks), where a prompt or a check
    /// would be out of place. `--privacy-check` (scripts/network-check.sh) keeps it: that check shows it sends nothing
    /// unasked.
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

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate()
        controller?.checkForUpdates(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updater?.canCheckForUpdates ?? false
        }
        return true
    }

    /// `GREENROOM_UPDATE_FEED`: another appcast, for testing an update end to end (scripts/update-check.sh). What it
    /// offers must still be signed with the key in Info.plist or by the same Developer ID.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["GREENROOM_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // Never send a system profile, whatever a feed or a default says.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.log.info("installing update \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Self.log.info("relaunching application for update")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.log.error("failed to download update \(item.displayVersionString, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        // Ignore the routine "already up to date" error code (SUNoUpdateError = 1001).
        if ns.domain == SUSparkleErrorDomain && ns.code == 1001 { return }
        Self.log.error("update cycle aborted (\(ns.domain, privacy: .public) \(ns.code)): \(ns.localizedDescription, privacy: .public)")
    }
}
