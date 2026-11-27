import AppKit

/// `Greenroom --jobs-check`: the job queue (`JobQueue`) on stand-in jobs that do nothing: lanes run one job at a time,
/// the "at once" limit holds the rest back, a held job keeps its place without starting, `prioritize` moves a job to
/// the front, a paused job keeps its lane and frees its place, a job sent back to the queue frees both, a gate is
/// asked again, and a job that ends inside its own start does not stall the queue. One `[greenroom] jobs: ok|FAIL ...`
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

        // The list and the chip, with jobs in every state.
        if let dir {
            _ = NSApplication.shared
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fresh()
            let build = job("Build fix-login", lane: "build:a"), queued = job("Build checkout-redesign", lane: "build:a"), held = job("Build main", lane: "build:a")
            let walk = job("Map onboarding-copy", lane: "walk", kind: .walk), compare = job("Compare fix-login with main", lane: "walk", kind: .compare)
            let fetch = job("Fetch the build of pull request #42", lane: nil, kind: .fetch), failed = job("Build settings-crash", lane: "build:b"), done = job("Map fix-login", lane: "walk2", kind: .walk)
            walk.onPause = { q.suspended(walk); return nil }
            for j in [done, failed] { q.submit(j) }
            q.finish(done, .done, detail: "41 screens")
            q.finish(failed, .failed("Execution failed for task ':app:compileDebugKotlin'.\ne: SettingsFragment.kt:42:17 Unresolved reference: prefs"))
            for j in [build, queued, held, walk, compare] { q.submit(j) }
            q.adopt(fetch)
            q.update(build, detail: "> Task :app:compileDebugKotlin")
            q.update(walk, detail: "23 screens found, 9 to open", fraction: .some(0.6))
            q.update(fetch, detail: "downloading app-debug.apk from run 8123")
            q.pause(walk)
            q.pause(held)
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
