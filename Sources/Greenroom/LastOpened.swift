import Foundation

/// What was on the stage last: a session (by its worktree) or a plain APK. With "Reopen what was open last" on (the
/// default), a launch opens it again instead of the empty stage. Kept in the app's preferences on this Mac only.
enum LastOpened: Equatable {
    case session(worktree: String)
    case apk(path: String)

    static let enabledKey = "reopenLast"
    private static let key = "lastOpened"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var stored: LastOpened? {
        guard let d = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return nil }
        if let wt = d["session"] { return .session(worktree: wt) }
        if let apk = d["apk"] { return .apk(path: apk) }
        return nil
    }

    static func note(_ last: LastOpened) {
        guard last != stored else { return }
        switch last {
        case .session(let wt): UserDefaults.standard.set(["session": wt], forKey: key)
        case .apk(let path): UserDefaults.standard.set(["apk": path], forKey: key)
        }
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: key) }

    /// Whether this launch reopens anything: not when files were handed to it, and not for a check or a script that
    /// started it with flags of its own (`--agent-check`, `--background`...).
    static func shouldReopen(openedFiles: Bool, arguments: [String] = CommandLine.arguments) -> Bool {
        enabled && !openedFiles && !arguments.dropFirst().contains { $0.hasPrefix("--") }
    }
}
