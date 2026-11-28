import AppKit

/// One piece of background work in the job queue: a build, a walk of an app, a comparison, a fetch of a CI build. The
/// part of the app that does the work makes it, says how to start, cancel and pause it, and tells the queue how it
/// goes; the queue decides when it starts and is what the person sees and acts on, whichever session they are in.
final class QueueJob {
    enum Kind {
        case build, walk, compare, verify, fetch, map

        var symbol: String {
            switch self {
            case .build: return "hammer"
            case .walk, .map: return "point.3.connected.trianglepath.dotted"
            case .compare: return "square.split.2x1"
            case .verify: return "checkmark.seal"
            case .fetch: return "arrow.down.circle"
            }
        }
    }

    enum State: Equatable {
        case queued
        case running
        /// Started and then stopped where it was: it keeps its lane, and uses none of the "at once" places.
        case paused
        case done
        case failed(String)
        case cancelled
    }

    enum Outcome: Equatable { case done, failed(String), cancelled }

    let id = UUID()
    let kind: Kind
    /// "Build fix-login", "Map checkout-redesign".
    let title: String
    /// What it works for: a worktree's path, "pr:ID", or nil.
    let owner: String?
    /// Jobs of one lane run one after the other (one build per repository, one walk at a time). Nil: no such limit.
    let lane: String?
    fileprivate(set) var state: State = .queued
    /// Queued, and held back by the person: it keeps its place and does not start until resumed.
    fileprivate(set) var held = false
    /// Why a queued job has not started ("waiting for Build main"), as of the queue's last look.
    fileprivate(set) var waiting: String?
    /// Its last line of progress.
    fileprivate(set) var detail = ""
    /// How far it has got, in what it works on (bytes, tasks, screens), when it can say.
    fileprivate(set) var progress: JobProgress?
    /// Where a download was when its speed was last measured.
    fileprivate var sample: (at: Date, done: Double)?
    let created = Date()
    fileprivate(set) var started: Date?
    fileprivate(set) var ended: Date?

    /// Starts the work: called by the queue, once each time the job leaves `queued`.
    var begin: (() -> Void)?
    /// Asked each time the queue could start it: a reason to wait a little longer, or nil.
    var gate: (() -> String?)?
    /// The person's Cancel. The owner ends the work and tells the queue with `finish`.
    var onCancel: (() -> Void)?
    /// The person's Pause of a running job: nil when it was taken (the owner then tells the queue with `suspended` or
    /// `requeue`), else why it cannot be paused now. A job with none cannot be paused while it runs.
    var onPause: (() -> String?)?
    /// The person's Resume of a paused job.
    var onResume: (() -> Void)?
    /// What pausing it while it runs does, for the button's tooltip.
    var pauseTip = "Pause it where it is"

    init(kind: Kind, title: String, owner: String?, lane: String?, detail: String = "") {
        self.kind = kind
        self.title = title
        self.owner = owner
        self.lane = lane
        self.detail = detail
    }

    /// Queued, running or paused: not over.
    var isActive: Bool { state == .queued || state == .running || state == .paused }
    var isPaused: Bool { state == .paused || (state == .queued && held) }
    var failure: String? { if case .failed(let why) = state { return why }; return nil }

    /// "waiting for Build main", "paused", the last line of its log: what a row says under the title.
    var statusLine: String {
        switch state {
        case .queued: return waiting ?? "waiting"
        case .running: return detail.isEmpty ? "running" : detail
        case .paused: return detail.isEmpty ? "paused" : "paused · " + detail
        case .done: return detail.isEmpty ? "done" : detail
        case .failed(let why): return why.split(separator: "\n").last.map(String.init) ?? why
        case .cancelled: return "cancelled"
        }
    }

    /// The share of its work that is done, when its progress has a total.
    var fraction: Double? { progress?.fraction }

    /// "23.1 of 48.0 MB · 3.2 MB/s", "214 of about 530 tasks": its progress in words, while it is under way.
    var measure: String? { state == .running || state == .paused ? progress?.words : nil }

    /// How long it has run (or ran).
    var elapsed: TimeInterval? { started.map { (ended ?? Date()).timeIntervalSince($0) } }
}

/// The job queue: every build, walk, comparison and fetch the app makes in the background, in the order they run.
///
/// - A job waits while its lane is taken (another build of its repository, another walk), while as many jobs run as
///   the person allows at once ("jobsAtOnce", none by default), while the person holds it, or while its own gate says
///   to (a walk yields to a build of its repository).
/// - The order of the list is the order jobs are tried in: `prioritize` moves one to the front.
/// - Finished jobs stay in the list for a while, with how they ended, so nothing started in one session is lost by
///   looking at another.
/// - Main thread only.
final class JobQueue {
    static let shared = JobQueue()
    /// Posted on the main thread when a job or the order changed (at most a few times a second).
    static let changed = Notification.Name("GreenroomJobQueueChanged")
    /// How many finished jobs are kept in the list.
    static let keep = 25

    private(set) var jobs: [QueueJob] = []
    private var pumping = false
    private var pumpAgain = false
    private var retry: Timer?
    private var notifyScheduled = false
    private var lastNotify = Date.distantPast
    /// How long a gated job waits before the queue asks its gate again (a check shortens it).
    var gateInterval: TimeInterval = 5

    /// How many jobs run at once across the app; 0 for no limit (lanes still apply).
    var limit: Int {
        get { max(0, UserDefaults.standard.integer(forKey: "jobsAtOnce")) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: "jobsAtOnce"); pump() }
    }
    /// For a check: the limit without the person's setting.
    var limitOverride: Int?
    private var effectiveLimit: Int { limitOverride ?? limit }

    /// Running first, then what waits in the order it will run, paused ones among them.
    var active: [QueueJob] { jobs.filter { $0.state == .running } + jobs.filter { $0.state == .paused } + jobs.filter { $0.state == .queued } }
    var running: [QueueJob] { jobs.filter { $0.state == .running } }
    var waiting: [QueueJob] { jobs.filter { $0.state == .queued || $0.state == .paused } }
    /// Finished jobs, the newest first.
    var recent: [QueueJob] { jobs.filter { !$0.isActive }.sorted { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) } }

    // MARK: For the parts of the app that do the work

    /// Adds a job to the end of the queue; it starts (`begin`) when its turn comes, which may be now.
    func submit(_ job: QueueJob) {
        guard !jobs.contains(where: { $0 === job }) else { return }
        job.state = .queued
        jobs.append(job)
        pump()
    }

    /// Adds a job the person started themselves and that is running already (a walk from the Screen Map, a fetch):
    /// it is shown and can be acted on like any other, and counts as running.
    func adopt(_ job: QueueJob) {
        guard !jobs.contains(where: { $0 === job }) else { return }
        job.state = .running
        job.started = Date()
        jobs.append(job)
        pump()
    }

    /// The job's progress: its last line, and how far it has got when it can say (`.some(nil)`: it no longer can).
    /// A download's speed is measured here, from one update to the next (`at`: when this one was taken).
    func update(_ job: QueueJob, detail: String? = nil, progress: JobProgress?? = nil, at now: Date = Date()) {
        var moved = false
        if let detail {
            let line = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, line != job.detail { job.detail = line; moved = true }
        }
        if var next = progress {
            if let p = next, p.unit == .bytes {
                var rate = job.progress?.unit == .bytes ? job.progress?.rate : nil
                if let s = job.sample, job.progress?.unit == .bytes, p.done >= s.done {
                    let dt = now.timeIntervalSince(s.at)
                    if dt >= 1 {
                        let r = (p.done - s.done) / dt
                        rate = rate.map { ($0 + r) / 2 } ?? r   // evened out: one slow second is not the speed
                        job.sample = (now, p.done)
                    }
                } else {
                    job.sample = (now, p.done)   // a new download, or one that started again
                    rate = nil
                }
                next?.rate = rate
            } else { job.sample = nil }
            if next != job.progress { job.progress = next; moved = true }
        }
        if moved { notify() }
    }

    /// The job is over. Its lane is free and the next job starts.
    func finish(_ job: QueueJob, _ outcome: QueueJob.Outcome, detail: String? = nil) {
        guard job.isActive, jobs.contains(where: { $0 === job }) else { return }
        switch outcome {
        case .done: job.state = .done
        case .failed(let why): job.state = .failed(why)
        case .cancelled: job.state = .cancelled
        }
        if let detail { job.detail = detail }
        job.held = false
        job.waiting = nil
        job.progress = nil
        job.sample = nil
        job.ended = Date()
        trim()
        pump()
    }

    /// The job leaves the list with nothing said (a walk a newer build replaced, a map that was there already).
    func forget(_ job: QueueJob) {
        guard let i = jobs.firstIndex(where: { $0 === job }) else { return }
        jobs.remove(at: i)
        if job.isActive { job.state = .cancelled; job.ended = Date() }
        pump()
    }

    /// A running job was stopped where it was (the owner took a Pause): it keeps its lane and frees its place.
    func suspended(_ job: QueueJob, detail: String? = nil) {
        guard job.state == .running else { return }
        job.state = .paused
        if let detail { job.detail = detail }
        pump()
    }

    /// A paused job runs again.
    func resumed(_ job: QueueJob) {
        guard job.state == .paused else { return }
        job.state = .running
        pump()
    }

    /// A running job went back to waiting (the owner stopped its work to start it again later): its lane is free. Held,
    /// it waits for the person's Resume.
    func requeue(_ job: QueueJob, held: Bool, detail: String? = nil) {
        guard job.isActive, jobs.contains(where: { $0 === job }) else { return }
        job.state = .queued
        job.held = held
        job.progress = nil
        job.sample = nil
        job.started = nil
        if let detail { job.detail = detail }
        pump()
    }

    // MARK: For the person

    func cancel(_ job: QueueJob) {
        guard job.isActive else { return }
        let was = job.state
        job.onCancel?()
        // A job nobody is running ends here; a running one ends when its owner says so.
        if job.isActive, was == .queued || job.onCancel == nil { finish(job, .cancelled) }
    }

    /// Holds a queued job, or pauses a running one. Gives why not, when it cannot be.
    @discardableResult
    func pause(_ job: QueueJob) -> String? {
        switch job.state {
        case .queued:
            guard !job.held else { return nil }
            job.held = true
            pump()
            return nil
        case .running:
            guard let pause = job.onPause else { return "\(job.title) cannot be paused while it runs. It can be cancelled." }
            let why = pause()
            if why == nil { notify() }
            return why
        default: return nil
        }
    }

    func resume(_ job: QueueJob) {
        switch job.state {
        case .queued:
            guard job.held else { return }
            job.held = false
            pump()
        case .paused:
            job.onResume?()
            if job.state == .paused { resumed(job) }
        default: break
        }
    }

    func canPause(_ job: QueueJob) -> Bool {
        (job.state == .queued && !job.held) || (job.state == .running && job.onPause != nil)
    }

    /// Runs it before everything else that waits: it moves to the front of the queue, and is no longer held.
    func prioritize(_ job: QueueJob) {
        guard job.state == .queued, let i = jobs.firstIndex(where: { $0 === job }) else { return }
        jobs.remove(at: i)
        jobs.insert(job, at: 0)
        job.held = false
        pump()
    }

    /// Whether anything that waits would run before it.
    func isFirst(_ job: QueueJob) -> Bool { jobs.first { $0.state == .queued } === job }

    func pauseAll() {
        for job in jobs where canPause(job) { _ = pause(job) }
    }

    func resumeAll() {
        for job in jobs where job.isPaused { resume(job) }
    }

    func clearRecent() {
        jobs.removeAll { !$0.isActive }
        notify()
    }

    // MARK: Running

    /// Starts every job whose turn it is. Called whenever something changed; asking again costs nothing.
    func pump() {
        if pumping { pumpAgain = true; return }
        pumping = true
        var gated = false
        repeat {
            pumpAgain = false
            gated = false
            var holders: [String: QueueJob] = [:]
            for job in jobs where job.state == .running || job.state == .paused { if let lane = job.lane, holders[lane] == nil { holders[lane] = job } }
            var runs = jobs.filter { $0.state == .running }.count
            let limit = effectiveLimit
            for job in jobs where job.state == .queued {
                if job.held { job.waiting = "paused"; continue }
                if let lane = job.lane, let holder = holders[lane] {
                    job.waiting = "waiting for \(holder.title)" + (holder.state == .paused ? ", which is paused" : "")
                    continue
                }
                if limit > 0, runs >= limit {
                    job.waiting = limit == 1 ? "waiting: jobs run one at a time" : "waiting: \(limit) jobs run at a time"
                    continue
                }
                if let why = job.gate?() { job.waiting = why; gated = true; continue }
                job.state = .running
                job.waiting = nil
                job.started = Date()
                if let lane = job.lane { holders[lane] = job }
                runs += 1
                job.begin?()
            }
        } while pumpAgain
        pumping = false
        // A gate has no way to say it opened: it is asked again in a while.
        if gated {
            if retry == nil {
                retry = Timer.scheduledTimer(withTimeInterval: gateInterval, repeats: false) { [weak self] _ in self?.retry = nil; self?.pump() }
            }
        } else { retry?.invalidate(); retry = nil }
        notify()
    }

    private func trim() {
        let ended = recent
        guard ended.count > Self.keep else { return }
        let drop = Set(ended[Self.keep...].map(\.id))
        jobs.removeAll { drop.contains($0.id) }
    }

    /// Tells whoever shows the queue, at most four times a second (a build's log moves faster than anyone reads).
    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        let wait = max(0, 0.25 - Date().timeIntervalSince(lastNotify))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.lastNotify = Date()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    /// For a check: an empty queue.
    func reset() {
        retry?.invalidate(); retry = nil
        jobs.removeAll()
        limitOverride = nil
    }
}
