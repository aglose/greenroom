import Foundation

// Walking only what changed (docs/MAP-HISTORY-PLAN.md, packages I1 and I2). Given the baseline snapshot (whose screens
// record what they depend on: `MapSnapshot.Deps`) and the files changed between its commit and the head, `decide` says
// whether a walk must redo everything (`.full`, with the reason in words) or only some screens (`.screens`, with each
// screen's reasons), the rest being carried from the baseline. `misses` keeps the quick walks honest: what a later full
// walk found different on a screen a quick walk carried. The decisions are pure; the git reading and the workspace's
// ledger (`impact.json` beside its snapshots) are at the end of the file.
enum MapImpact {
    /// One line of `git diff --name-status --no-renames`: "M", "A", "D", "T"... and the path.
    struct FileChange: Equatable {
        var status: String
        var path: String
    }

    enum Decision: Equatable {
        /// Walk everything: why, in words ("build files changed").
        case full(String)
        /// Walk these screens (ids of the baseline, in its order) and carry the rest; each with why.
        case screens([String], [String: [String]])

        var isFull: Bool { if case .full = self { return true } else { return false } }
    }

    struct Input {
        var baseline: MapSnapshot
        var changes: [FileChange]
        /// `git diff -U0 --no-renames BASE HEAD -- <the changed res/values* files>`.
        var valueDiff: String = ""
        /// The engine and the profile of the walk about to be made.
        var engine: String
        var profile: MapProfile
        /// The workspace's extra full-walk patterns (a directory "app/src/main/java/com/x/", or a glob with `*`).
        var fullWalkPatterns: [String] = []
    }

    // MARK: What a path is

    enum Kind: Equatable {
        /// Cannot change what the app shows: docs, tests, CI, editor files.
        case ignored
        /// Changes everything, or cannot be traced to screens: why.
        case full(String)
        /// A Kotlin or Java source file.
        case source
        /// A resource file: `type/name` ("layout/trip_row").
        case resource(String)
        /// A file of `res/values*/`: what changed is read from the diff.
        case values
    }

    private static let docExtensions: Set<String> = ["md", "markdown", "rst", "adoc", "txt"]
    private static let docNames: Set<String> = ["license", "licence", "notice", "authors", "contributors", "codeowners", "changelog", "readme"]
    private static let ciRoots: Set<String> = [".github", ".gitlab", ".circleci", ".buildkite", ".idea", ".vscode", ".fleet", ".greenroom", "docs", "doc", "fastlane"]
    private static let ciFiles: Set<String> = [".gitlab-ci.yml", "jenkinsfile", "bitrise.yml", "azure-pipelines.yml", ".travis.yml", "codemagic.yaml",
                                               ".gitignore", ".gitattributes", ".editorconfig", ".mailmap", "lint.xml", "lint-baseline.xml", "detekt.yml",
                                               "detekt-config.yml", ".ktlint", ".pre-commit-config.yaml", "renovate.json", ".renovaterc"]

    static func kind(of path: String) -> Kind {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last else { return .ignored }
        let lower = file.lowercased()
        let ext = (file as NSString).pathExtension.lowercased()
        let base = ((lower as NSString).deletingPathExtension as NSString).lastPathComponent

        // Tests: src/test, src/androidTest and their variants (testDebug, androidTestRelease, testFixtures, sharedTest).
        if let s = parts.firstIndex(of: "src"), s + 1 < parts.count {
            let set = parts[s + 1]
            if set.hasPrefix("test") || set.hasPrefix("androidTest") || set == "sharedTest" { return .ignored }
        }
        if parts.count > 1, ciRoots.contains(parts[0].lowercased()) { return .ignored }
        if ciFiles.contains(lower) || lower.hasSuffix(".iml") { return .ignored }

        // Build files.
        if parts.first == "buildSrc" || parts.first == "build-logic" || parts.first == "gradle" { return .full("build files changed") }
        if lower.hasSuffix(".gradle") || lower.hasSuffix(".gradle.kts") || lower == "gradle.properties" || lower.hasSuffix(".versions.toml")
            || lower == "gradlew" || lower == "gradlew.bat" { return .full("build files changed") }
        if lower == "androidmanifest.xml" { return .full("the manifest changed") }
        if ext == "pro" || (lower.hasPrefix("proguard") && ext == "txt") { return .full("shrinker rules changed") }
        if parts.dropLast().contains("assets") { return .full("assets changed") }

        // Resources: .../res/<type>[-qualifiers]/<name>.<ext>
        if let r = parts.lastIndex(of: "res"), r + 2 == parts.count - 1 {
            let type = parts[r + 1].split(separator: "-").first.map(String.init) ?? parts[r + 1]
            if type == "values" { return .values }
            let name = file.split(separator: ".").first.map(String.init) ?? file
            return .resource(type + "/" + name)
        }
        if ext == "kt" || ext == "java" { return .source }
        if docExtensions.contains(ext) || docNames.contains(base) || docNames.contains(lower) { return .ignored }
        return .full("a changed file Greenroom cannot place (\(path))")
    }

    // MARK: Values

    private static let element = try! NSRegularExpression(pattern: #"<([A-Za-z][\w.-]*)((?:\s+[\w:.-]+\s*=\s*"[^"]*")*)\s*/?>"#)
    private static let attribute = try! NSRegularExpression(pattern: #"([\w:.-]+)\s*=\s*"([^"]*)""#)

    /// The resources a changed line of a values file names, as `type/name`; nil when the line changes something it
    /// does not name (an `<item>` of a style or an array, the middle of a long string).
    static func valueResources(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("<?xml") || t.hasPrefix("<resources") || t == "</resources>" { return [] }
        if t.hasPrefix("<!--"), t.hasSuffix("-->") { return [] }
        let ns = t as NSString
        var out: [String] = []
        for m in element.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            let attrs = ns.substring(with: m.range(at: 2)) as NSString
            var a: [String: String] = [:]
            for am in attribute.matches(in: attrs as String, range: NSRange(location: 0, length: attrs.length)) {
                a[attrs.substring(with: am.range(at: 1))] = attrs.substring(with: am.range(at: 2))
            }
            guard let name = a["name"] else { continue }
            let type: String?
            switch tag {
            case "item", "public": type = a["type"]
            case "string-array", "integer-array", "array": type = "array"
            case "declare-styleable": type = "styleable"
            case "eat-comment", "skip": type = nil
            default: type = tag
            }
            guard let type else { return nil }
            out.append(type + "/" + name)
        }
        return out.isEmpty ? nil : out
    }

    /// The added and removed lines of a unified diff, by the file they belong to (its new path, or its old one when deleted).
    static func changedLines(_ diff: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        var oldPath: String?
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") { current = nil; oldPath = nil; continue }
            if line.hasPrefix("--- ") { oldPath = line.hasPrefix("--- a/") ? String(line.dropFirst(6)) : nil; continue }
            if line.hasPrefix("+++ ") {
                current = line.hasPrefix("+++ b/") ? String(line.dropFirst(6)) : oldPath
                if let c = current, out[c] == nil { out[c] = [] }
                continue
            }
            guard let c = current, let first = line.first, first == "+" || first == "-" else { continue }
            out[c, default: []].append(String(line.dropFirst()))
        }
        return out
    }

    // MARK: The decision

    /// A resource name as R spells it: dots in style names are underscores there.
    private static func norm(_ r: String) -> String { r.replacingOccurrences(of: ".", with: "_") }

    static func sourceMatches(_ path: String, _ source: String) -> Bool {
        !source.isEmpty && (path == source || path.hasSuffix("/" + source))
    }

    /// A workspace pattern: a directory ("app/src/main/java/com/x/") matches what is under it; anything else is a glob.
    static func patternMatches(_ pattern: String, _ path: String) -> Bool {
        if pattern.hasSuffix("/") { return path.hasPrefix(pattern) }
        return fnmatch(pattern, path, 0) == 0
    }

    /// Full walk, or which screens to walk again. See the file's head and the plan for the rules.
    static func decide(_ input: Input) -> Decision {
        let b = input.baseline
        // A new engine no longer starts a full walk: the map is kept and its carried screens are verified after the walk
        // (`History.WalkPlan.engineChanged`), with a full walk only when the new engine reads a screen differently.
        if b.profile.id != input.profile.id { return .full("the walk's settings changed") }
        if let why = b.depsUnreliable { return .full("the last walk's record of what screens depend on cannot be trusted (\(why))") }
        guard let start = b.startDeps, b.screens.contains(where: { $0.deps != nil }) else {
            return .full("the last walk did not record what its screens depend on")
        }
        let startResources = Set(start.resources.map(norm))
        let lines = changedLines(input.valueDiff)

        var reasons: [String: [String]] = [:]
        func select(_ why: String, where test: (MapSnapshot.Deps) -> Bool) -> Int {
            var n = 0
            for s in b.screens {
                guard let d = s.deps, test(d) else { continue }
                n += 1
                if reasons[s.id]?.contains(why) != true { reasons[s.id, default: []].append(why) }
            }
            return n
        }
        func resource(_ r: String, _ path: String) -> Decision? {
            if startResources.contains(norm(r)) { return .full("app start changed (\(r))") }
            _ = select("\(r) changed") { $0.resources.contains { norm($0) == norm(r) } }
            return nil
        }

        for c in input.changes {
            let path = c.path
            let kind = kind(of: path)
            if kind == .ignored { continue }
            if let p = input.fullWalkPatterns.first(where: { patternMatches($0, path) }) {
                return .full("a file under \(p) changed, where a quick walk missed a change before")
            }
            switch kind {
            case .ignored: continue
            case .full(let why): return .full(why)
            case .source:
                if start.sources.contains(where: { sourceMatches(path, $0) }) { return .full("app start changed (\((path as NSString).lastPathComponent))") }
                let n = select("\((path as NSString).lastPathComponent) changed") { $0.sources.contains { sourceMatches(path, $0) } }
                if n == 0 { return .full("a changed source file is on no screen the last walk recorded (\(path))") }
            case .resource(let r):
                if let d = resource(r, path) { return d }
            case .values:
                guard let changed = lines[path] else { return .full("the change to \(path) could not be read") }
                for l in changed {
                    guard let names = valueResources(l) else { return .full("a changed line in \(path) names no resource") }
                    for r in names { if let d = resource(r, path) { return d } }
                }
            }
        }
        // Screens the last walk has no record for are walked again: nothing says they are safe to carry.
        for s in b.screens where s.deps == nil { reasons[s.id, default: []].append("no record of what it depends on") }
        return .screens(b.screens.map(\.id).filter { reasons[$0] != nil }, reasons)
    }

    // MARK: Misses (I2)

    /// A screen a quick walk carried that a full walk found different.
    struct Miss: Codable, Equatable {
        var screen: String
        var title: String
        /// What differs, in words ("its structure changed").
        var why: String
        /// The quick walk's commit, and the commit its entry was carried from.
        var quickCommit: String
        var carriedFrom: String
        /// The full walk (or verification) that found it.
        var foundBy: String
        /// The files changed from `carriedFrom` to `quickCommit` that could matter: the change the quick walk judged harmless.
        var files: [String] = []
        var found: String = ""
    }

    /// The carried screens of `quick` that differ in `full`: by id, its captures (both settled), its texts and its routes.
    /// A screen `full` does not have counts only when `full` finished (else it may not have been reached).
    static func differing(full: MapSnapshot, quick: MapSnapshot) -> [(screen: MapSnapshot.Screen, why: String)] {
        let byID = Dictionary(full.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func routes(_ s: MapSnapshot, _ id: String) -> [String: String] {
            Dictionary(s.edges.filter { $0.from == id }.map { ($0.cmd, $0.to ?? "UNFOLLOWED") }, uniquingKeysWith: { a, _ in a })
        }
        var out: [(MapSnapshot.Screen, String)] = []
        for q in quick.screens where q.carriedFrom != nil {
            guard let f = byID[q.id] else {
                if !full.cutShort { out.append((q, "its structure changed")) }
                continue
            }
            let steady = q.settled && f.settled && q.flaky == nil && f.flaky == nil
            if steady, Set(q.captures.keys).intersection(f.captures.keys).contains(where: { q.captures[$0] != f.captures[$0] }) {
                out.append((q, "its capture changed")); continue
            }
            if steady, Set(q.texts) != Set(f.texts) { out.append((q, "its text changed")); continue }
            if routes(quick, q.id) != routes(full, q.id) { out.append((q, "its routes changed")) }
        }
        return out
    }

    /// The full-walk patterns a miss adds: each of its files' directories.
    static func patterns(for files: [String]) -> [String] {
        var out: [String] = []
        for f in files {
            let dir = (f as NSString).deletingLastPathComponent
            let p = dir.isEmpty ? f : dir + "/"
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// The row's words for misses: "1 screen changed that the last quick walk did not redo".
    static func missWords(_ n: Int) -> String {
        "\(n) screen\(n == 1 ? "" : "s") changed that the last quick walk did not redo"
    }

    // MARK: Git

    /// The files changed from `base` to `head`, and the -U0 diff of the values files among them. Nil when git could not say.
    static func changes(base: String, head: String, in dir: URL) async -> (changes: [FileChange], valueDiff: String)? {
        guard !base.hasPrefix("-"), !head.hasPrefix("-"),
              let out = await Git.run(["diff", "--name-status", "--no-renames", "-z", base, head, "--"], in: dir) else { return nil }
        let fields = out.split(separator: "\0").map(String.init)
        var changes: [FileChange] = []
        var i = 0
        while i + 1 < fields.count {
            changes.append(FileChange(status: fields[i], path: fields[i + 1]))
            i += 2
        }
        let values = changes.map(\.path).filter { kind(of: $0) == .values }
        var diff = ""
        if !values.isEmpty {
            guard let d = await Git.run(["diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", base, head, "--"] + values, in: dir) else { return nil }
            diff = d
        }
        return (changes, diff)
    }

    // MARK: The workspace's ledger

    /// What a workspace's quick walks have learned, kept beside its snapshots (`<store>/impact.json`).
    struct Ledger: Codable, Equatable {
        /// Walks of commits on the main branch, by profile id. No longer counted (every tenth was a full walk); read so an older ledger keeps its shape.
        var mainWalks: [String: Int] = [:]
        /// Extra full-walk patterns (I2 adds each missed file's directory).
        var patterns: [String] = []
        var misses: [Miss] = []

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mainWalks = try c.decodeIfPresent([String: Int].self, forKey: .mainWalks) ?? [:]
            patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
            misses = try c.decodeIfPresent([Miss].self, forKey: .misses) ?? []
        }
    }

    /// How often a walk of main is full whatever the impact says.
}

extension MapStore {
    private static let ledgerLock = NSLock()
    private var ledgerFile: URL { folder.appendingPathComponent("impact.json") }

    var ledger: MapImpact.Ledger {
        (try? Data(contentsOf: ledgerFile)).flatMap { MapJSON.decode(MapImpact.Ledger.self, from: $0) } ?? MapImpact.Ledger()
    }

    /// Changes the ledger under a lock and writes it whole; returns what `change` returned.
    @discardableResult
    func updateLedger<T>(_ change: (inout MapImpact.Ledger) -> T) -> T {
        MapStore.ledgerLock.lock(); defer { MapStore.ledgerLock.unlock() }
        var l = ledger
        let r = change(&l)
        try? MapJSON.encode(l).write(to: ledgerFile, options: .atomic)
        return r
    }

    /// Records misses (once each: by screen and quick commit) and, with `patterns`, adds their files' directories as
    /// full-walk patterns.
    func record(misses: [MapImpact.Miss], patterns: Bool = true) {
        guard !misses.isEmpty else { return }
        updateLedger { l in
            for m in misses where !l.misses.contains(where: { $0.screen == m.screen && $0.quickCommit == m.quickCommit }) {
                l.misses.append(m)
                if patterns { for p in MapImpact.patterns(for: m.files) where !l.patterns.contains(p) { l.patterns.append(p) } }
            }
        }
    }
}
