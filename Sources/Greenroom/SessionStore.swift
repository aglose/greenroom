import CryptoKit
import Foundation

/// What Sessions keeps on disk, under the app's state folder (private to the user):
///
///     sessions/workspaces.json         the workspaces and their settings
///     builds/<key>/{build.json,app.apk}   one folder per distinct APK; app.apk is an APFS clone
final class SessionStore {
    static let shared = SessionStore(root: Engine.shared.state)

    let root: URL
    private let fm = FileManager.default
    /// Held while a build is filed or the history is read or written (several background queues do both).
    private let lock = NSLock()

    init(root: URL) { self.root = root }

    var workspacesFile: URL { root.appendingPathComponent("sessions/workspaces.json") }
    var builds: URL { root.appendingPathComponent("builds", isDirectory: true) }
    func folder(of key: String) -> URL { builds.appendingPathComponent(key, isDirectory: true) }

    private func privateFolder(_ dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Workspaces

    /// The stored workspaces. A file that cannot be read is moved aside (`workspaces.json.bad`), never taken for
    /// empty: the next save would erase what the person added.
    func loadWorkspaces() -> [Workspace] {
        guard let data = try? Data(contentsOf: workspacesFile) else { return [] }
        if let list = try? Self.decoder.decode([Workspace].self, from: data) { return list }
        let bad = workspacesFile.appendingPathExtension("bad")
        try? fm.removeItem(at: bad)
        try? fm.moveItem(at: workspacesFile, to: bad)
        NSLog("Greenroom: workspaces.json could not be read; kept as workspaces.json.bad")
        return []
    }

    func saveWorkspaces(_ list: [Workspace]) {
        do {
            try privateFolder(workspacesFile.deletingLastPathComponent())
            try Self.encoder.encode(list).write(to: workspacesFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspacesFile.path)
        } catch {
            NSLog("Greenroom: could not save the workspaces: \(error.localizedDescription)")
        }
    }

    // MARK: Data slots

    /// `gr` and the first 8 hex of the SHA-256 of the worktree's path: stable for a folder, different for each.
    static func slot(for worktree: URL) -> String {
        slotLock.lock(); defer { slotLock.unlock() }
        if let known = slotCache[worktree.path] { return known }
        let digest = SHA256.hash(data: Data(worktree.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        let slot = "gr" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        slotCache[worktree.path] = slot
        return slot
    }
    private static let slotLock = NSLock()
    private static var slotCache: [String: String] = [:]

    // MARK: Builds

    /// First 16 hex of the file's SHA-256, read in pieces. Off the main thread for a big APK.
    static func key(of file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let piece = try? h.read(upToCount: 1 << 20), !piece.isEmpty { hasher.update(data: piece) }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Files `apk` as a build: `builds/<key>/app.apk` (cloned, else copied) and `build.json`. A build already stored
    /// under its key is not written again; the existing record stays, as the first source of a build is its source.
    /// The APK is made under a temporary name and renamed into place, so `app.apk` is always whole, and two
    /// records of one file at once both succeed.
    func record(apk: URL, source: Build.Source, sha: String?, ref: String?, dirty: Bool, date: Date? = nil) -> Build? {
        guard let key = Self.key(of: apk) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let dir = folder(of: key)
        let stored = dir.appendingPathComponent("app.apk")
        let size = (try? apk.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        func whole(_ f: URL) -> Bool { (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size }
        if let existing = build(key), whole(existing.apk) { return existing }
        do {
            try privateFolder(builds)
            try privateFolder(dir)
            if !whole(stored) {
                let temp = dir.appendingPathComponent("app.apk.\(UUID().uuidString.prefix(8)).part")
                defer { try? fm.removeItem(at: temp) }
                // An APFS clone shares the blocks; anywhere else (or across volumes) a plain copy does the job.
                if clonefile(apk.path, temp.path, 0) != 0 { try fm.copyItem(at: apk, to: temp) }
                guard whole(temp), rename(temp.path, stored.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
            let when = date ?? (try? apk.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let build = Build(key: key, apk: stored, source: source, sha: sha, ref: ref, dirty: dirty, date: when)
            try Self.encoder.encode(build).write(to: dir.appendingPathComponent("build.json"), options: .atomic)
            return build
        } catch {
            NSLog("Greenroom: could not store the build: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: History and pruning

    /// Which builds each worktree made, newest first (`sessions/history.json`, by worktree path).
    private var historyFile: URL { root.appendingPathComponent("sessions/history.json") }

    private func loadHistory() -> [String: [String]] {
        (try? Data(contentsOf: historyFile)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    private func saveHistory(_ h: [String: [String]]) {
        try? privateFolder(historyFile.deletingLastPathComponent())
        try? JSONEncoder().encode(h).write(to: historyFile, options: .atomic)
    }

    func history(of worktree: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loadHistory()[worktree] ?? []
    }

    /// Notes that `worktree` made the build `key` (newest first, each key once).
    func note(build key: String, of worktree: String) {
        lock.lock(); defer { lock.unlock() }
        var h = loadHistory()
        var keys = h[worktree] ?? []
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        h[worktree] = keys
        saveHistory(h)
    }

    /// The plan's pruning: of each worktree only its last `keep` builds are kept, and nothing of a worktree that is
    /// gone. A build folder goes only when no worktree's history lists it any more; folders no history ever listed
    /// (a base build, a build of someone else's making) are not touched here.
    func prune(live: Set<String>, keep: Int = 3) {
        lock.lock(); defer { lock.unlock() }
        var h = loadHistory()
        var dropped = Set<String>()
        for (worktree, keys) in h {
            if !live.contains(worktree) { dropped.formUnion(keys); h[worktree] = nil }
            else if keys.count > keep { dropped.formUnion(keys.dropFirst(keep)); h[worktree] = Array(keys.prefix(keep)) }
        }
        guard !dropped.isEmpty else { return }
        saveHistory(h)
        let kept = Set(h.values.flatMap { $0 })
        for key in dropped where !kept.contains(key) { try? fm.removeItem(at: folder(of: key)) }
    }

    func build(_ key: String) -> Build? {
        guard let data = try? Data(contentsOf: folder(of: key).appendingPathComponent("build.json")) else { return nil }
        return try? Self.decoder.decode(Build.self, from: data)
    }

    // MARK: Gradle outputs

    /// Whether `file` is an APK Gradle left in `build/outputs/apk` of the worktree or of a module one folder down:
    /// not an intermediate, a test APK, a fixture or any other `.apk` in the tree.
    static func isBuildOutput(_ file: URL, in worktree: URL) -> Bool {
        guard file.pathExtension.lowercased() == "apk" else { return false }
        let name = file.lastPathComponent
        if name.contains("androidTest") || name.contains("unaligned") { return false }
        let root = worktree.resolvingSymlinksInPath().pathComponents
        let parts = file.resolvingSymlinksInPath().pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return false }
        let rel = Array(parts.dropFirst(root.count))
        for at in 0...1 where rel.count > at + 3 && rel[at] == "build" && rel[at + 1] == "outputs" && rel[at + 2] == "apk" { return true }
        return false
    }

    /// The newest `.apk` under a worktree's Gradle outputs (`isBuildOutput`).
    static func newestAPK(in worktree: URL) -> Session.Outputs? {
        let fm = FileManager.default
        var roots = [worktree.appendingPathComponent("build/outputs/apk", isDirectory: true)]
        if let top = try? fm.contentsOfDirectory(at: worktree, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for d in top where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                roots.append(d.appendingPathComponent("build/outputs/apk", isDirectory: true))
            }
        }
        var best: Session.Outputs?
        for r in roots where fm.fileExists(atPath: r.path) {
            guard let walk = fm.enumerator(at: r, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: []) else { continue }
            for case let f as URL in walk where isBuildOutput(f, in: worktree) {
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true,
                      let d = v.contentModificationDate else { continue }
                if best == nil || d > best!.date { best = Session.Outputs(apk: f, date: d) }
            }
        }
        return best
    }
}
