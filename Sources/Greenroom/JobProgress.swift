import Foundation

/// How far a job has got, counted in what it works on: the bytes of a download, the tasks of a build, the steps of a
/// CI run, the screens of a walk. The job list draws it as a bar and says it in words beside the job's last line.
struct JobProgress: Equatable {
    enum Unit: Equatable {
        case bytes, tasks, steps, screens
        /// Out of a hundred, with nothing counted behind it.
        case percent
        /// A recipe's own word: "files", "modules".
        case other(String)
    }

    var done: Double
    /// Nil: counted, with no end known. The bar moves without a share.
    var total: Double?
    var unit: Unit
    /// The total is what the last run like this one came to, not what this one said.
    var estimated = false
    /// Bytes a second, measured by the queue between updates.
    var rate: Double?

    init(_ done: Double, of total: Double? = nil, _ unit: Unit, estimated: Bool = false) {
        self.done = max(0, done)
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
        self.unit = unit
        self.estimated = estimated
    }

    /// A guessed total that the work has passed says nothing any more.
    private var outgrown: Bool { estimated && done >= (total ?? .infinity) }

    /// The share done, when there is a total. A guessed total never fills the bar: only the end of the job does.
    var fraction: Double? {
        guard let total else { return nil }
        if estimated { return outgrown ? 0.97 : min(0.97, done / total) }
        return min(1, done / total)
    }

    /// "23.1 of 48.0 MB · 3.2 MB/s", "214 of about 530 tasks", "9 of 23 screens", "12 steps", "40%".
    var words: String {
        let total = outgrown ? nil : self.total
        switch unit {
        case .bytes:
            let scale = Self.scale(for: total ?? done)
            var s = Self.amount(done, scale) + (total.map { " of " + Self.amount($0, scale) } ?? "") + " " + scale.name
            if let rate, rate > 0 { s += " · " + Self.bytes(rate) + "/s" }
            return s
        case .percent:
            return "\(Int((fraction ?? 0) * 100))%"
        case .tasks, .steps, .screens, .other:
            let count = Int(total ?? done)
            let name: String = {
                switch unit {
                case .tasks: return count == 1 ? "task" : "tasks"
                case .steps: return count == 1 ? "step" : "steps"
                case .screens: return count == 1 ? "screen" : "screens"
                case .other(let word): return word
                default: return ""
                }
            }()
            guard let total else { return "\(Int(done)) \(name)" }
            return "\(Int(done)) of \(estimated ? "about " : "")\(Int(total)) \(name)"
        }
    }

    // MARK: Bytes

    private struct Scale { var name: String; var size: Double; var digits: Int }

    /// One unit for both numbers of "23.1 of 48.0 MB": the total's.
    private static func scale(for bytes: Double) -> Scale {
        if bytes >= 1_000_000_000 { return Scale(name: "GB", size: 1_000_000_000, digits: 2) }
        if bytes >= 1_000_000 { return Scale(name: "MB", size: 1_000_000, digits: 1) }
        return Scale(name: "KB", size: 1000, digits: 0)
    }

    private static func amount(_ bytes: Double, _ scale: Scale) -> String { String(format: "%.\(scale.digits)f", bytes / scale.size) }

    /// "48.0 MB".
    static func bytes(_ n: Double) -> String {
        let s = scale(for: n)
        return amount(n, s) + " " + s.name
    }
}

/// Reads a recipe's output for how far it has got.
///
/// - A recipe that knows says so in a line of its own, which is kept out of the log:
///   `greenroom: progress DONE/TOTAL UNIT` (`greenroom: progress 1048576/52428800 bytes`, `... 3/12 steps`), with `?`
///   for a total it does not know and `~` before one that may still grow (`7/~19 steps`: "7 of about 19 steps"), or
///   `greenroom: progress 40%`. `greenroom: progress -` takes it back: the next stretch of work has no measure.
/// - Gradle's plain console names each task as it runs (`> Task :app:compileDebugKotlin`). They are counted, against
///   how many the last build like this one ran (`expectedTasks`) when that is known.
///
/// Whichever spoke last is the progress.
struct RecipeProgressReader {
    static let directive = "greenroom: progress"

    /// How many tasks the last build like this one ran: the total the count is held against, as a guess.
    var expectedTasks: Int?
    /// The Gradle tasks seen so far.
    private(set) var tasks = 0
    private var seen = Set<String>()
    private(set) var progress: JobProgress?

    init(expectedTasks: Int? = nil) { self.expectedTasks = expectedTasks.flatMap { $0 > 0 ? $0 : nil } }

    /// Takes one line of output. `hidden`: the line was for Greenroom alone and is not part of the log.
    /// `changed`: `progress` is not what it was.
    mutating func read(_ line: String) -> (hidden: Bool, changed: Bool) {
        if line.hasPrefix("> Task ") {
            // A task whose output comes in several pieces has its header printed again: it is one task.
            let name = line.dropFirst(7).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            guard !name.isEmpty, seen.insert(name).inserted else { return (false, false) }
            tasks += 1
            return (false, set(JobProgress(Double(tasks), of: expectedTasks.map(Double.init), .tasks, estimated: true)))
        }
        guard line.hasPrefix("greenroom:") else { return (false, false) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(Self.directive) else { return (false, false) }
        let words = trimmed.dropFirst(Self.directive.count).split(separator: " ").map(String.init)
        guard let first = words.first else { return (true, false) }
        if first == "-" { return (true, set(nil)) }
        if first.hasSuffix("%"), let p = Double(first.dropLast()) { return (true, set(JobProgress(min(100, p), of: 100, .percent))) }
        let parts = first.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let done = Double(parts[0]), done.isFinite else { return (true, false) }
        // "~19": about nineteen, a total that may still grow.
        let about = parts[1].hasPrefix("~")
        let total = Double(about ? parts[1].dropFirst() : parts[1]).flatMap { $0.isFinite ? $0 : nil }
        let unit: JobProgress.Unit = {
            switch words.dropFirst().first?.lowercased() {
            case "bytes", "byte": return .bytes
            case "tasks", "task": return .tasks
            case "steps", "step", nil: return .steps
            case "screens", "screen": return .screens
            case .some(let word): return .other(String(word.prefix(24)))
            }
        }()
        return (true, set(JobProgress(done, of: total, unit, estimated: about && total != nil)))
    }

    private mutating func set(_ p: JobProgress?) -> Bool {
        guard p != progress else { return false }
        progress = p
        return true
    }
}

/// How many Gradle tasks each kind of build ran the last time it was built: what the next one's count is held against,
/// so its bar has an end before Gradle has said how much there is to do. Kept in the app's settings, by workspace,
/// recipe, module and variant.
enum BuildTaskCounts {
    private static let key = "buildTaskCounts"
    /// Workspaces remembered at most (the oldest names go first, whichever they are).
    private static let keep = 200

    static func name(workspace: String, recipe: String, module: String, variant: String) -> String {
        [workspace, recipe, module, variant].joined(separator: "\u{1f}")
    }

    static func expected(_ name: String, in defaults: UserDefaults = .standard) -> Int? {
        let n = (defaults.dictionary(forKey: key) as? [String: Int])?[name] ?? 0
        return n > 0 ? n : nil
    }

    /// A build ended well having run `tasks` tasks. A build that ran none (a recipe that is not Gradle) is not noted.
    static func note(_ tasks: Int, for name: String, in defaults: UserDefaults = .standard) {
        guard tasks > 0 else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
        all[name] = tasks
        // Workspaces that are gone (a deleted clone, a check's folder) are not kept.
        let fm = FileManager.default
        all = all.filter { fm.fileExists(atPath: String($0.key.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")) || $0.key == name }
        if all.count > keep { for gone in all.keys.sorted().prefix(all.count - keep) where gone != name { all[gone] = nil } }
        defaults.set(all, forKey: key)
    }
}
