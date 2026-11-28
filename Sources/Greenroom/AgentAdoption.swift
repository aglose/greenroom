import Foundation

/// A repository adds itself (docs/AGENT-FIRST-SPEC.md, "Onboarding"): the first tool call from a worktree with an
/// Android app in it adds that repository to Sessions, so the agent brings the work and nobody prepares a
/// repository by hand. `AgentServer.connect` decides; this is what it decides with.
///
/// What the person removed stays removed. The repositories taken out of Sessions are kept here, in the state
/// folder, and an agent's call never adds one of them again: only adding it by hand takes it off the list.
enum AgentAdoption {
    private static let lock = NSLock()
    private static var cached: Set<String>?
    private static var file: URL { Engine.shared.state.appendingPathComponent("sessions/removed.json") }

    static func key(_ root: URL) -> String { root.resolvingSymlinksInPath().standardizedFileURL.path }

    /// Off in a check unless it asks for it (GREENROOM_CHECK_ADOPT), so a check's own folders are never added.
    static var enabled: Bool { !Engine.agentCheck || ProcessInfo.processInfo.environment["GREENROOM_CHECK_ADOPT"] != nil }

    /// A check (`--…-check`) other than the agent's keeps the list in memory: its temporary repositories never reach
    /// the person's own state folder. The agent check has a state folder of its own (GREENROOM_STATE).
    private static let inMemory = !Engine.agentCheck && CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-check") }

    private static func load() -> Set<String> {
        if let cached { return cached }
        let list = inMemory ? [] : (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        cached = Set(list)
        return cached ?? []
    }

    private static func save(_ set: Set<String>) {
        cached = set
        if inMemory { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(set.sorted()) else { return }
        try? data.write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The person took this repository out of Sessions: an agent's call does not put it back.
    static func isRemoved(_ root: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load().contains(key(root))
    }

    static func noteRemoved(_ root: URL) {
        lock.lock(); defer { lock.unlock() }
        var set = load()
        if set.insert(key(root)).inserted { save(set) }
    }

    /// Added by hand: agents may bring it again, should it be removed and added once more.
    static func noteAdded(_ root: URL) {
        lock.lock(); defer { lock.unlock() }
        var set = load()
        if set.remove(key(root)) != nil { save(set) }
    }
}
