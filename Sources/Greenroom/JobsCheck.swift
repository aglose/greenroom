import AppKit

/// `Greenroom --jobs-check`: the job queue (`JobQueue`) on stand-in jobs that do nothing: lanes run one job at a time,
/// the "at once" limit holds the rest back, a held job keeps its place without starting, `prioritize` moves a job to
/// the front, a paused job keeps its lane and frees its place, a job sent back to the queue frees both, a gate is
/// asked again, and a job that ends inside its own start does not stall the queue; then how far a job has got
/// (`JobProgress`): what a recipe's lines say, the words, a download's speed, the task count a build is held against. One `[greenroom] jobs: ok|FAIL ...`
/// line per step, then `jobs check: PASS|FAIL`; exits 0 or 1. No engine. With a DIR, the list and the chip are drawn
/// with stand-in jobs in every state and written there as `jobs-list.png` and `jobs-chip.png`, to look at.
enum JobsCheck {
    /// Draws a view as it would be in the window, into a PNG.
    private static func write(_ view: NSView, to file: URL) -> Bool {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Design.stage
        window.contentView = view
        window.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }

    static func run(dir: URL? = nil) -> Never {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("[greenroom] jobs: \(ok ? "ok" : "FAIL") \(what)")
        }
        let q = JobQueue.shared
        var begun: [String] = []
        func job(_ name: String, lane: String?, kind: QueueJob.Kind = .build) -> QueueJob {
            let j = QueueJob(kind: kind, title: name, owner: nil, lane: lane)
            j.begin = { begun.append(name) }
            return j
        }
        func fresh() { q.reset(); q.limitOverride = 0; begun = [] }

        // Lanes.
        fresh()
        let a = job("a", lane: "x"), b = job("b", lane: "x"), c = job("c", lane: "y")
        q.submit(a); q.submit(b); q.submit(c)
        expect(a.state == .running && b.state == .queued && c.state == .running, "one job of a lane runs, another lane's runs beside it")
        expect(b.waiting == "waiting for a", "a waiting job says what it waits for (\(b.waiting ?? "nothing"))")
        q.finish(a, .done)
        expect(b.state == .running && begun == ["a", "c", "b"], "the next job of a lane starts when the lane is free")
        expect(a.state == .done && a.ended != nil && q.recent.first === a, "a finished job stays in the list, with how it ended")

        // The limit.
        fresh()
        q.limitOverride = 1
        let d = job("d", lane: "x"), e = job("e", lane: "y"), f = job("f", lane: "z")
        q.submit(d); q.submit(e); q.submit(f)
        expect(d.state == .running && e.state == .queued && f.state == .queued, "with one job at a time, the others wait whatever their lane")
        expect(e.waiting?.contains("one at a time") == true, "and say so (\(e.waiting ?? "nothing"))")
        q.finish(d, .failed("it broke"))
        expect(e.state == .running && f.state == .queued && d.failure == "it broke", "they start in the order of the list, a failure keeps its reason")
        q.limitOverride = 0
        q.pump()
        expect(f.state == .running, "lifting the limit starts what waited for it")

        // Holding and prioritizing.
        fresh()
        let g = job("g", lane: "x"), h = job("h", lane: "x"), i = job("i", lane: "x"), k = job("k", lane: "x")
        q.submit(g); q.submit(h); q.submit(i); q.submit(k)
        q.pause(h)
        expect(h.held && h.isPaused && h.waiting == "paused", "a waiting job can be held")
        q.prioritize(k)
        expect(q.isFirst(k), "a job can be moved to the front of what waits")
        q.finish(g, .done)
        expect(k.state == .running && h.state == .queued && i.state == .queued, "the job moved to the front runs next")
        q.finish(k, .done)
        expect(i.state == .running && h.state == .queued, "a held job is passed over, and keeps its place")
        q.resume(h)
        q.finish(i, .done)
        expect(h.state == .running && begun == ["g", "k", "i", "h"], "resumed, it runs when its turn comes")
        q.finish(h, .done)

        // Pausing a running job where it is.
        fresh()
        q.limitOverride = 1
        let l = job("l", lane: "x"), m = job("m", lane: "x"), n = job("n", lane: "y")
        var resumedL = false
        l.onPause = { q.suspended(l); return nil }
        l.onResume = { resumedL = true }
        q.submit(l); q.submit(m); q.submit(n)
        expect(q.canPause(l) && q.pause(l) == nil && l.state == .paused, "a running job that can be paused is")
        expect(m.state == .queued && m.waiting == "waiting for l, which is paused", "it keeps its lane (\(m.waiting ?? "nothing"))")
        expect(n.state == .running, "and frees its place for another lane's job")
        q.resume(l)
        expect(l.state == .running && resumedL, "resuming it tells its owner and it runs again")
        let fixed = job("fixed", lane: nil)
        q.adopt(fixed)
        expect(!q.canPause(fixed) && q.pause(fixed) != nil && fixed.state == .running, "a job that cannot be paused says why and goes on")
        q.finish(l, .done); q.finish(n, .done); q.finish(m, .done); q.finish(fixed, .done)

        // A build's pause: stopped and sent back to the queue, held.
        fresh()
        let o = job("o", lane: "x"), p = job("p", lane: "x")
        o.onPause = { q.requeue(o, held: true); return nil }
        q.submit(o); q.submit(p)
        q.pause(o)
        expect(o.state == .queued && o.held && p.state == .running, "a job sent back to the queue frees its lane and waits, held")
        q.resume(o)
        expect(o.state == .queued && !o.held && o.waiting == "waiting for p", "resumed, it waits for its lane again")
        q.finish(p, .done)
        expect(o.state == .running && begun == ["o", "p", "o"], "and is started a second time")

        // Cancel.
        fresh()
        let r = job("r", lane: "x"), s = job("s", lane: "x")
        var cancelledR = false
        r.onCancel = { cancelledR = true; q.finish(r, .cancelled) }
        q.submit(r); q.submit(s)
        q.cancel(s)
        expect(s.state == .cancelled && begun == ["r"], "a waiting job is cancelled without ever starting")
        q.cancel(r)
        expect(cancelledR && r.state == .cancelled, "a running job's owner is told to end it")

        // Gates, and a job that ends inside its own start.
        fresh()
        var open = false
        let t = job("t", lane: "x"), u = job("u", lane: "x"), v = job("v", lane: "x")
        t.gate = { open ? nil : "not yet" }
        u.begin = { begun.append("u"); q.forget(u) }   // a map that was there already
        q.submit(t)
        expect(t.state == .queued && t.waiting == "not yet", "a gated job waits and says why")
        q.submit(u); q.submit(v)
        expect(v.state == .running && !q.jobs.contains { $0 === u } && begun == ["u", "v"], "a job that ends as it starts does not stall the lane; a gated job is passed")
        open = true
        q.finish(v, .done)
        expect(t.state == .running, "the gate is asked again, and the job starts when it opens")
        q.finish(t, .done)

        // Everything at once, and the list's length.
        fresh()
        let w = job("w", lane: "x"), x = job("x", lane: "x"), y = job("y", lane: nil)
        w.onPause = { q.suspended(w); return nil }
        q.submit(w); q.submit(x); q.adopt(y)
        q.pauseAll()
        expect(w.state == .paused && x.held && y.state == .running, "Pause All holds what waits and pauses what can be")
        q.resumeAll()
        expect(w.state == .running && !x.held, "Resume All lets them go on")
        for j in [w, x, y] { q.cancel(j) }
        for n in 0..<(JobQueue.keep + 10) { let j = job("old\(n)", lane: nil); q.submit(j); q.finish(j, .done) }
        expect(q.recent.count == JobQueue.keep && q.active.isEmpty, "the list keeps the last \(JobQueue.keep) finished jobs")
        q.clearRecent()
        expect(q.jobs.isEmpty, "Clear Finished empties it")

        // How far a job has got: what a recipe's output says.
        var reader = RecipeProgressReader(expectedTasks: 4)
        var said = reader.read("> Task :app:preBuild UP-TO-DATE")
        expect(!said.hidden && said.changed && reader.progress == JobProgress(1, of: 4, .tasks, estimated: true), "a Gradle task is counted against the last build's count, and stays in the log")
        said = reader.read("> Task :app:preBuild")
        expect(!said.changed && reader.tasks == 1, "a task named twice is one task")
        _ = reader.read("> Task :app:compileDebugKotlin"); _ = reader.read("> Task :app:dexDebug"); _ = reader.read("> Task :app:packageDebug")
        expect(reader.progress?.fraction == 0.97 && reader.progress?.words == "4 tasks", "a guessed total never fills the bar, and is dropped from the words once passed (\(reader.progress?.words ?? "nothing"))")
        said = reader.read("greenroom: progress 1048576/52428800 bytes")
        expect(said.hidden && said.changed && reader.progress == JobProgress(1_048_576, of: 52_428_800, .bytes), "a progress line is read and kept out of the log")
        _ = reader.read("greenroom: progress 3/12")
        expect(reader.progress == JobProgress(3, of: 12, .steps), "a count without a word is steps")
        _ = reader.read("greenroom: progress 7/? modules")
        expect(reader.progress?.fraction == nil && reader.progress?.words == "7 modules", "an unknown total is a count with no share (\(reader.progress?.words ?? "nothing"))")
        _ = reader.read("greenroom: progress 7/~19 steps")
        expect(reader.progress?.words == "7 of about 19 steps" && reader.progress?.estimated == true, "a total that may grow is said as about that many (\(reader.progress?.words ?? "nothing"))")
        _ = reader.read("greenroom: progress 40%")
        expect(reader.progress?.fraction == 0.4 && reader.progress?.words == "40%", "a percentage is a share")
        said = reader.read("greenroom: progress nonsense")
        expect(said.hidden && !said.changed, "a progress line that says nothing is dropped and changes nothing")
        said = reader.read("greenroom: progress -")
        expect(said.hidden && said.changed && reader.progress == nil, "a recipe can take its progress back")
        said = reader.read("greenroom: sandbox-created sb-1")
        expect(!said.hidden && !said.changed, "Greenroom's other lines are left alone")
        var first = RecipeProgressReader()
        _ = first.read("> Task :app:preBuild")
        expect(first.progress?.fraction == nil && first.progress?.words == "1 task", "a first build counts its tasks with no end known")

        // The words.
        expect(JobProgress(23_100_000, of: 48_000_000, .bytes).words == "23.1 of 48.0 MB", "bytes are said in the total's unit (\(JobProgress(23_100_000, of: 48_000_000, .bytes).words))")
        expect(JobProgress(512_000, .bytes).words == "512 KB" && JobProgress(1_500_000_000, of: 2_000_000_000, .bytes).words == "1.50 of 2.00 GB", "small and large downloads read well")
        expect(JobProgress(214, of: 530, .tasks, estimated: true).words == "214 of about 530 tasks" && JobProgress(9, of: 23, .screens).words == "9 of 23 screens", "counts say what they count")
        expect(JobProgress(30, of: 20, .screens).fraction == 1, "a share is never more than all of it")

        // A download's speed, measured between updates.
        fresh()
        let load = job("load", lane: nil, kind: .fetch)
        q.adopt(load)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        q.update(load, progress: .some(JobProgress(0, of: 48_000_000, .bytes)), at: t0)
        expect(load.progress?.rate == nil && load.fraction == 0, "a download that just began has no speed yet")
        q.update(load, progress: .some(JobProgress(1_000_000, of: 48_000_000, .bytes)), at: t0.addingTimeInterval(0.4))
        expect(load.progress?.rate == nil, "less than a second is too short to measure")
        q.update(load, progress: .some(JobProgress(6_000_000, of: 48_000_000, .bytes)), at: t0.addingTimeInterval(2))
        expect(load.progress?.rate == 3_000_000 && load.measure == "6.0 of 48.0 MB · 3.0 MB/s", "its speed is what arrived over the time it took (\(load.measure ?? "nothing"))")
        q.update(load, progress: .some(JobProgress(7_000_000, of: 48_000_000, .bytes)), at: t0.addingTimeInterval(3))
        expect(load.progress?.rate == 2_000_000, "and is evened out from one measure to the next")
        q.update(load, progress: .some(JobProgress(9, of: 23, .steps)), at: t0.addingTimeInterval(4))
        q.update(load, progress: .some(JobProgress(100, of: 48_000_000, .bytes)), at: t0.addingTimeInterval(5))
        expect(load.progress?.rate == nil, "a new download starts its measure again")
        q.update(load, progress: .some(nil))
        expect(load.progress == nil && load.fraction == nil && load.measure == nil, "progress can be taken back")
        q.update(load, progress: .some(JobProgress(5, of: 10, .steps)))
        q.finish(load, .done)
        expect(load.progress == nil, "a finished job has none")
        let half = job("half", lane: nil), unknown = job("unknown", lane: nil)
        q.adopt(half); q.adopt(unknown)
        q.update(half, progress: .some(JobProgress(1, of: 2, .steps)))
        expect(JobsChip.fraction(of: q.running) == nil, "the chip has no share while a running job cannot say its own")
        q.update(unknown, progress: .some(JobProgress(1, of: 4, .steps)))
        expect(JobsChip.fraction(of: q.running) == 0.375, "and the mean of them when they all can")

        // The task count a build is held against, in settings of its own.
        let suite = "greenroom.jobs-check.\(ProcessInfo.processInfo.processIdentifier)"
        if let defaults = UserDefaults(suiteName: suite) {
            let here = FileManager.default.currentDirectoryPath
            let name = BuildTaskCounts.name(workspace: here, recipe: "local", module: "app", variant: "debug")
            expect(BuildTaskCounts.expected(name, in: defaults) == nil, "a build never made has no count")
            BuildTaskCounts.note(0, for: name, in: defaults)
            expect(BuildTaskCounts.expected(name, in: defaults) == nil, "a build that ran no task leaves none")
            BuildTaskCounts.note(531, for: name, in: defaults)
            BuildTaskCounts.note(12, for: BuildTaskCounts.name(workspace: "/nowhere/greenroom-gone", recipe: "local", module: "app", variant: "debug"), in: defaults)
            BuildTaskCounts.note(88, for: BuildTaskCounts.name(workspace: here, recipe: "local", module: "app", variant: "release"), in: defaults)
            expect(BuildTaskCounts.expected(name, in: defaults) == 531, "a build that ended well is remembered by workspace, recipe, module and variant")
            expect(BuildTaskCounts.expected(BuildTaskCounts.name(workspace: "/nowhere/greenroom-gone", recipe: "local", module: "app", variant: "debug"), in: defaults) == nil, "a workspace that is gone is forgotten")
            defaults.removePersistentDomain(forName: suite)
        }

        // The list and the chip, with jobs in every state.
        if let dir {
            _ = NSApplication.shared
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fresh()
            let build = job("Build fix-login", lane: "build:a"), queued = job("Build checkout-redesign", lane: "build:a"), held = job("Build main", lane: "build:a")
            let walk = job("Map onboarding-copy", lane: "walk", kind: .walk), compare = job("Compare fix-login with main", lane: "walk", kind: .compare)
            let fetch = job("Fetch the build of pull request #42", lane: nil, kind: .fetch), waitingCI = job("Fetch the build of main", lane: nil, kind: .fetch)
            let first = job("Build new-module", lane: "build:c"), verify = job("Verify checkout-redesign", lane: "walk3", kind: .verify), failed = job("Build settings-crash", lane: "build:b"), done = job("Map fix-login", lane: "walk2", kind: .walk)
            walk.onPause = { q.suspended(walk); return nil }
            for j in [done, failed] { q.submit(j) }
            q.finish(done, .done, detail: "41 screens")
            q.finish(failed, .failed("Execution failed for task ':app:compileDebugKotlin'.\ne: SettingsFragment.kt:42:17 Unresolved reference: prefs"))
            for j in [build, queued, held, walk, compare, first, verify] { q.submit(j) }
            q.adopt(fetch); q.adopt(waitingCI)
            // Each kind of work, counted in what it works on; one job that cannot count yet.
            q.update(build, detail: "> Task :app:compileDebugKotlin", progress: .some(JobProgress(214, of: 530, .tasks, estimated: true)))
            q.update(first, detail: "> Task :feature:search:kspDebugKotlin", progress: .some(JobProgress(37, .tasks)))
            q.update(walk, detail: "23 screens found, 9 to open", progress: .some(JobProgress(14, of: 23, .screens)))
            let began = Date().addingTimeInterval(-3)
            q.update(fetch, detail: "downloading app-debug from run 8123", progress: .some(JobProgress(13_500_000, of: 48_000_000, .bytes)), at: began)
            q.update(fetch, progress: .some(JobProgress(23_100_000, of: 48_000_000, .bytes)), at: began.addingTimeInterval(3))
            q.update(waitingCI, detail: "waiting for CI run 8131: Unit tests", progress: .some(JobProgress(7, of: 19, .steps, estimated: true)))
            q.update(verify, detail: "starting the simulator")
            q.pause(walk)
            q.pause(held)
            JobsPopover.tallest = 2000   // the whole list in the picture, not what fits before it scrolls
            let list = JobsPopover()
            expect(write(list.view, to: dir.appendingPathComponent("jobs-list.png")), "the list is drawn with jobs in every state")
            let chip = JobsChip()
            chip.refresh()
            expect(!chip.isHidden && write(chip, to: dir.appendingPathComponent("jobs-chip.png")), "the chip is there while the queue has jobs")
        }

        q.reset()
        print("jobs check: " + (failures == 0 ? "PASS" : "FAIL"))
        exit(failures == 0 ? 0 : 1)
    }
}
