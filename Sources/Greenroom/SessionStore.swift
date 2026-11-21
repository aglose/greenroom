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

    func loadWorkspaces() -> [Workspace] {
        guard let data = try? Data(contentsOf: workspacesFile),
              let list = try? Self.decoder.decode([Workspace].self, from: data) else { return [] }
        return list
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
        let digest = SHA256.hash(data: Data(worktree.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        return "gr" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Builds

    /// First 16 hex of the file's SHA-256, read in pieces. Off the main thread for a big APK.
    static func key(of file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let piece = try? h.read(upToCount: 1 << 20), !piece.isEmpty { hasher.update(data: piece) }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Files `apk` as a build: `builds/<key>/app.apk` (cloned, else copied) and `build.json`. A file already stored
    /// under its key is not written again; the existing record stays, as the first source of a build is its source.
    func record(apk: URL, source: Build.Source, sha: String?, ref: String?, dirty: Bool, date: Date? = nil) -> Build? {
        guard let key = Self.key(of: apk) else { return nil }
        let dir = folder(of: key)
        let stored = dir.appendingPathComponent("app.apk")
        if let existing = build(key) { return existing }
        do {
            try privateFolder(builds)
            try privateFolder(dir)
            if !fm.fileExists(atPath: stored.path) {
                // An APFS clone shares the blocks; anywhere else (or across volumes) a plain copy does the job.
                if clonefile(apk.path, stored.path, 0) != 0 { try fm.copyItem(at: apk, to: stored) }
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

    func build(_ key: String) -> Build? {
        guard let data = try? Data(contentsOf: folder(of: key).appendingPathComponent("build.json")) else { return nil }
        return try? Self.decoder.decode(Build.self, from: data)
    }

    // MARK: Gradle outputs

    /// The newest `.apk` under a worktree's Gradle outputs (`build/outputs/apk` of the worktree or of a module one
    /// folder down). Test APKs and unaligned intermediates do not count.
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
            for case let f as URL in walk where f.pathExtension.lowercased() == "apk" {
                let name = f.lastPathComponent
                if name.contains("androidTest") || name.contains("unaligned") { continue }
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true,
                      let d = v.contentModificationDate else { continue }
                if best == nil || d > best!.date { best = Session.Outputs(apk: f, date: d) }
            }
        }
        return best
    }
}
