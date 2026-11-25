import Foundation
import AppKit

/// What a signed-in walk does first: a hidden simulator on a throwaway data slot runs one of the person's scripts
/// (Scripts: their variables, `gr`), then quits, so the slot is left signed in. The crawler then walks that slot as
/// it is (`--keep-data`; each simulator of the walk gets its own clone of it), and the slot goes when the walk has ended.
///
/// - The person's own data (`gdphone`, a session's slot) is never touched: the slot is made for this walk.
/// - The script runs online even when the walk is offline: a sign-in needs its server.
/// - Its output is masked like any script's and only its last line is shown; nothing is written to disk.
final class MapSignIn {
    enum Outcome { case ready(slot: String), failed(String), cancelled }

    let script: Scripts.Script
    /// The throwaway slot (SlotClone's prefix, so one a crash leaves is swept a day later).
    let slot = SlotClone.freshName()
    /// What it is doing, for the map's status line (main thread).
    var onStatus: ((String) -> Void)?

    private let apk: URL
    private let worktree: URL?
    private var sim: Simulator?
    private var run: ScriptRun?
    private var cancelled = false
    private var done: ((Outcome) -> Void)?
    private var log: URL?

    private static var live: [ObjectIdentifier: MapSignIn] = [:]
    private static let quitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        // The main thread ends here, so nothing queued to it runs: stop the script and the device directly.
        for s in live.values { s.cancelled = true; s.run?.cancel(); s.sim?.quit(); s.sim?.waitUntilExit(); discard(s.slot) }
    }

    /// How long the script may take: a sign-in that waits on an email or a slow server, but not forever.
    static let timeout: TimeInterval = 300

    init(apk: URL, script: Scripts.Script, worktree: URL?) {
        self.apk = apk
        self.script = script
        self.worktree = script.fromWorktree ? worktree : nil
    }

    /// Starts the hidden simulator, waits for its first frame, runs the script, quits the simulator. `completion`
    /// on the main thread, once; on `.ready` the caller owns the slot (`discard` it after the walk).
    func start(completion: @escaping (Outcome) -> Void) {
        _ = MapSignIn.quitObserver
        MapSignIn.live[ObjectIdentifier(self)] = self
        done = completion
        let engine = Engine.shared
        let s: Simulator
        do {
            try engine.prepare()
            let log = engine.logs.appendingPathComponent("map-sign-in-\(UUID().uuidString.prefix(8)).log")
            self.log = log
            s = Simulator(apk: apk, log: log)
            try s.start(launcher: engine.launcher, stateDir: engine.engineState, options: ["--data-slots", slot], controlToken: engine.supportsControlToken)
        } catch {
            return end(.failed("The device for \(script.name) could not start: \(error.localizedDescription)"))
        }
        sim = s
        onStatus?("Starting a device to run \(script.name)…")
        let deadline = Date().addingTimeInterval(150)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.cancelled { timer.invalidate(); return }
            if s.state == .running, s.framesShown > 0, s.controlPort != nil {
                timer.invalidate()
                self.runScript(on: s)
            } else if !s.isAlive || Date() > deadline {
                timer.invalidate()
                self.end(.failed("The device for \(self.script.name) did not start (no first frame)."))
            }
        }
    }

    private func runScript(on s: Simulator) {
        guard let r = ScriptRun(script: script, sim: s, worktree: worktree) else {
            return end(.failed("The device for \(script.name) has no control channel."))
        }
        run = r
        let name = script.name
        onStatus?("Signing in: running \(name)…")
        r.onLine = { [weak self] line in
            let l = line.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { self?.onStatus?("Signing in (\(name)): \(l)") }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let o = r.runSync(timeout: MapSignIn.timeout)
            // A script can end well without having signed in (one that only checks the network when its variables are
            // missing): what the app shows afterwards says. Read here, off the main thread, while the device still runs.
            let leftAt = (o.code == 0 && !o.cancelled && !o.timedOut && o.failure == nil) ? ScreenNode.parse(s.sendSync("nodes")) : []
            DispatchQueue.main.async {
                guard let self else { return }
                if o.cancelled || self.cancelled { return self.end(.cancelled) }
                if let f = o.failure { return self.end(.failed(f)) }
                if o.timedOut { return self.end(.failed("\(name) did not finish within \(Int(MapSignIn.timeout / 60)) minutes.")) }
                guard o.code == 0 else {
                    let last = o.output.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    return self.end(.failed("\(name) failed (exit \(o.code ?? -1))" + (last.map { ": \($0)" } ?? "")))
                }
                if MapSignIn.stillAtSignIn(leftAt) {
                    let last = o.output.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    return self.end(.failed("\(name) ended, but the app still shows a password field, so the walk would run signed out"
                                            + (last.map { ". The script said: \($0)" } ?? ".")))
                }
                self.onStatus?("Signed in with \(name); starting the walk…")
                self.end(.ready(slot: self.slot))
            }
        }
    }

    /// Whether the screen a sign-in script left the app on is still a sign-in: a password field is on it. A signed-in
    /// app rarely shows one (a change-password screen is not where a sign-in script ends).
    static func stillAtSignIn(_ nodes: [ScreenNode]) -> Bool {
        nodes.contains { $0.password }
    }

    /// Stops the script and the device; the slot is removed. The completion gets `.cancelled`.
    func cancel() {
        guard done != nil else { return }
        cancelled = true
        run?.cancel()
        if run == nil { end(.cancelled) }   // still starting: nothing else will end it
    }

    /// How long the last sign-in's engine held its slot after the device's process had exited (for checks).
    static var lastRelease: TimeInterval = 0

    /// Quits the device and waits for it to let go of the slot (the crawler needs it), then reports.
    private func end(_ outcome: Outcome) {
        guard let done else { return }
        self.done = nil
        let s = sim, log = self.log, slot = self.slot
        var outcome = outcome
        s?.quit()
        DispatchQueue.global(qos: .userInitiated).async {
            s?.waitUntilExit()
            // The device's process is the engine's client; the JVM that held the slot can still be exiting. The crawler
            // refuses a slot that is held, so the walk starts only once it is free.
            let exited = Date()
            if case .ready = outcome {
                let free = SlotClone.waitUntilFree(slot, in: Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true))
                MapSignIn.lastRelease = Date().timeIntervalSince(exited)
                if !free { outcome = .failed("The device for \(self.script.name) did not let go of its data after it quit.") }
            }
            if case .ready = outcome {} else { MapSignIn.discard(slot) }
            if let log { try? FileManager.default.removeItem(at: log) }
            DispatchQueue.main.async {
                MapSignIn.live[ObjectIdentifier(self)] = nil
                done(outcome)
            }
        }
    }

    /// Removes the walk's slot (any thread).
    static func discard(_ slot: String) {
        SlotClone.remove(slot, in: Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true))
    }
}
