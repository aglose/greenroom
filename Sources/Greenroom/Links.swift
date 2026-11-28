import AppKit

/// `greenroom://` links: a place in Greenroom's window that a message, a pull request comment or an agent's answer
/// can point at. (The Debug copy answers `greenroom-debug://`, so a link never opens the wrong one.)
///
///     greenroom://                      the window
///     greenroom://connect               the Connect screen
///     greenroom://apk                   the APK screen
///     greenroom://session?path=DIR      the session of the worktree at DIR, and its simulator if one runs
///
/// A link only navigates. Any web page can ask macOS to open one, so a link never runs an APK, never builds, never
/// adds a repository and never changes a setting: `session` shows a session Greenroom already has, and one it does
/// not have is said so. What an agent may do goes through the agent interface, which a web page cannot reach.
enum Links {
    static var scheme: String { Variant.isDebug ? "greenroom-debug" : "greenroom" }

    static func handles(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

    /// The link to a worktree's session.
    static func session(_ worktree: URL) -> String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "session"
        c.queryItems = [URLQueryItem(name: "path", value: worktree.path)]
        return c.string ?? "\(scheme)://session"
    }

    /// Goes where the link says. Answers what is now shown, or why nothing is (false). On the main thread.
    static func open(_ url: URL, in workbench: Workbench) -> (said: String, ok: Bool) {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // greenroom://connect has the place as its host; greenroom:connect and greenroom:///connect as its path.
        let place = [parts?.host ?? "", parts?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""]
            .first { !$0.isEmpty }?.lowercased() ?? ""
        switch place {
        case "", "open":
            return ("Greenroom's window", true)
        case "connect":
            workbench.connectAgents(nil)
            return ("the Connect screen", true)
        case "apk":
            workbench.runAPK(nil)
            return ("the APK screen", true)
        case "session":
            guard let path = parts?.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/"), !path.contains("\0") else {
                return ("a session link names its worktree: \(scheme)://session?path=/the/worktree", false)
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard let s = workbench.sessions.session(atWorktree: folder) else {
                // Not added from a link: a repository adds itself on its agent's first call, or by File > Add Repository.
                return ("Greenroom has no session for \(folder.lastPathComponent). A link does not add one: an agent's first call from that worktree does, or File > Add Repository…", false)
            }
            workbench.sessions.show(s)
            workbench.showDevices()   // off the Connect or APK screen, which would cover it
            let name = s.branch ?? s.shortHead
            if let sim = workbench.sessions.simulator(for: s) {
                workbench.select(sim)
                return ("\(name), and its simulator", true)
            }
            return ("\(name) (no simulator runs for it)", true)
        default:
            return ("Greenroom has no place called \(place.prefix(40)): a link is \(scheme)://connect, \(scheme)://apk or \(scheme)://session?path=DIR", false)
        }
    }

    /// A link macOS handed the app (clicked in a browser, a chat or a terminal).
    static func opened(_ url: URL, in workbench: Workbench) {
        let (said, ok) = open(url, in: workbench)
        bringForward(workbench)
        if !ok { workbench.toast.show(said, problem: true) }
    }

    static func bringForward(_ workbench: Workbench) {
        workbench.window.makeKeyAndOrderFront(nil)
        if !CommandLine.arguments.contains("--background") { NSApp.activate() }
    }
}

/// What harnesses' hooks said (`greenroom hook EVENT`): which harness, its session's id, the folder it works in and
/// the event's name, and nothing else. No prompt, no transcript, no file's content reaches here, because the command
/// sends none. Kept in memory only, newest 200.
final class HookLog {
    struct Event { let time: Date; let harness: String; let session: String; let cwd: URL; let event: String }
    static let shared = HookLog()
    private var kept: [Event] = []
    private let lock = NSLock()

    var events: [Event] { lock.lock(); defer { lock.unlock() }; return kept }

    private static func word(_ raw: Any?, _ allowed: String, max: Int) -> String? {
        guard let s = raw as? String, !s.isEmpty, s.count <= max,
              s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || allowed.unicodeScalars.contains($0) }) else { return nil }
        return s
    }

    /// Keeps one event if it is well formed: names of plain characters, and a folder that exists. Answers it.
    @discardableResult
    func add(_ params: [String: Any]) -> Event? {
        guard let event = HookLog.word(params["event"], "_-", max: 40),
              let harness = HookLog.word(params["harness"], "_-. ", max: 40),
              let path = params["cwd"] as? String, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let session = HookLog.word(params["session"], "_-.:", max: 128) ?? ""
        let e = Event(time: Date(), harness: harness, session: session, cwd: URL(fileURLWithPath: path, isDirectory: true), event: event)
        lock.lock()
        kept.append(e)
        if kept.count > 200 { kept.removeFirst(kept.count - 200) }
        lock.unlock()
        return e
    }
}
