import AppKit
import AVFoundation

extension AppDelegate {
    /// `Greenroom --changes-check DIR APK`: see ChangesCheck.
    func changesCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--changes-check"), i + 2 < args.count else { return }
        workbench.window.setContentSize(NSSize(width: 1500, height: 960))
        workbench.window.center()
        ChangesCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2])) { [self] in captureWindow(to: $0) }
    }
}

/// `Greenroom --changes-check DIR APK`: the Changes view end to end, on a temporary git repository whose worktree has the
/// test app as its build. The base is the same app with another `apksim_slot_seed` setting (the crawler's `--base-option`),
/// both walked from `apksim://slot`, one tap deep.
///
///  - a base with no build (an earlier commit) shows the offer and starts nothing; an unknown branch fails with a message;
///  - the build against itself: no differences, a clear state, no tour;
///  - the build against the changed one: exactly the slot screen changed, nothing new or gone, with a difference image;
///  - the sheet: counts in the header, the Screens tab lists that screen with three pictures, the Map marks it, the
///    Summary names it; Copy summary's Markdown names it; the report is there; the same pair again runs nothing;
///  - the change tour: two playable MP4s read back with AVFoundation, a chapter per changed screen;
///  - the menus and the palette offer Changes.
///
/// One `[greenroom] changes: ok|FAIL ...` line per step, then `changes check: PASS|FAIL`. Everything is made in a fresh
/// subfolder of DIR (`changes-check`; its state folder is the engine's, see Engine.init); DIR itself is never deleted. A
/// window screenshot of each tab goes to that folder.
enum ChangesCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL, capture: @escaping (URL) -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions
            let ev = sessions.evidence
            let sheet = wb.changesSheet

            let base = dir.resolvingSymlinksInPath().appendingPathComponent("changes-check", isDirectory: true)
            func say(_ s: String) { fputs("[greenroom] changes: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 120, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
            func run(_ exe: String, _ args: [String], in folder: URL? = nil) -> String? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = folder
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            }
            func git(_ args: [String], in folder: URL) -> String? {
                run("/usr/bin/git", ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + args, in: folder)
            }
            func shot(_ name: String) {
                capture(base.appendingPathComponent(name))
                // The window server's picture is blank or flat while the screen is locked: the sheet's own views, drawn by AppKit, are kept too.
                if let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) {
                    sheet.flatForCapture(true)
                    sheet.cacheDisplay(in: sheet.bounds, to: rep)
                    sheet.flatForCapture(false)
                    try? rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathComponent("view-" + name))
                }
                say("screenshot \(name) \(fm.fileExists(atPath: base.appendingPathComponent(name).path) ? "saved" : "NOT saved")")
            }
            @MainActor func finish() -> Never {
                ev.shutdown()
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("changes check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }

            for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != "engine-state" {
                try? fm.removeItem(at: old)
            }
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            // The engine's state folder is kept between runs: logs an earlier run left are not this run's to count.
            for f in (try? fm.contentsOfDirectory(at: Engine.shared.logs, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("tour-") { try? fm.removeItem(at: f) }
            expect(Engine.shared.state.path.hasPrefix(base.path + "/"), "the check runs on a state folder of its own (\(Engine.shared.state.lastPathComponent))")

            // A repository with a worktree on its own branch, one commit ahead of main.
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            let wt = base.appendingPathComponent("wt-feature", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try? "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try? "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            guard git(["init", "-q", "-b", "main"], in: repo) != nil, git(["add", "."], in: repo) != nil, git(["commit", "-q", "-m", "first"], in: repo) != nil,
                  let firstSha = git(["rev-parse", "HEAD"], in: repo)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  git(["worktree", "add", "-q", "-b", "feature", wt.path], in: repo) != nil else {
                say("FAIL could not make the repository (is /usr/bin/git there?)"); failures += 1; finish()
            }
            try? "changed\n".write(to: wt.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            _ = git(["commit", "-q", "-am", "second"], in: wt)

            var variants = 0
            func variant() -> URL? {
                variants += 1
                let folder = base.appendingPathComponent("variant\(variants)", isDirectory: true)
                try? fm.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
                try? "build \(variants)\n".write(to: folder.appendingPathComponent("assets/greenroom-check.txt"), atomically: true, encoding: .utf8)
                let out = folder.appendingPathComponent("app.apk")
                guard (try? fm.copyItem(at: apk, to: out)) != nil, run("/usr/bin/zip", ["-q", out.path, "assets/greenroom-check.txt"], in: folder) != nil else { return nil }
                return out
            }
            let headFile = wt.appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk")
            guard let vh = variant(), let vb = variant() else { say("FAIL could not make the builds"); failures += 1; finish() }
            try? fm.createDirectory(at: headFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: vh, to: headFile)

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)
            ev.budget = Evidence.Budget(depth: 1, seconds: 240, jobs: 2)
            _ = await sessions.addRepository(wt).value
            func row() -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-feature" } }
            _ = await wait("the row", 30) { row()?.outputs != nil }
            guard let a = row() else { say("FAIL the row is missing"); failures += 1; finish() }
            sessions.setAuto(.off, for: a)   // nothing is walked but what this check asks for
            expect(ev.started == 0, "nothing is walked by itself")

            func crawlers() -> Int {
                ((run("/usr/bin/pgrep", ["-f", "scripts/crawl.py .*changes-check/state"]) ?? "").split(separator: "\n")).count
            }
            let seedOption = "--setting global:apksim_slot_seed=changed"

            // The menus and the palette.
            let deviceMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Device" }
            let item = deviceMenu?.items.first { $0.title == "Changes…" }
            expect(item?.keyEquivalent == "d" && item?.keyEquivalentModifierMask == [.command], "Device > Changes… is ⌘D")
            expect(sessions.buildMenuItems(for: a).contains { $0.title == "Changes…" }, "a session row's menu has Changes…")
            expect(sessions.paletteItems().contains { $0.title.hasPrefix("Changes") }, "the palette has Changes")

            // 1. A base that cannot be resolved: the offer, and nothing started.
            sheet.open(session: a, compare: false)
            expect(sheet.isOpen && sheet.stateTitleText == "Compare this build", "the sheet opens on a session and waits for a base")
            sheet.compare(base: .ref(firstSha), name: "first commit")
            let offered = await wait("the offer", 30) { sheet.stateTitleText.contains("no build") }
            expect(offered && !sheet.offerButtonTitles.isEmpty && sheet.stateDetailText.contains("CI"), "a base with no build shows the offer as a button (\(sheet.offerButtonTitles.joined(separator: ", ")))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            expect(ev.started == 0 && crawlers() == 0, "the offer started no walk and no build")
            shot("0-offer.png")
            sheet.compare(base: .ref("no-such-branch-here"))
            let failed = await wait("the failure", 30) { sheet.stateTitleText == "Could not compare" }
            expect(failed && sheet.stateDetailText.contains("No branch or commit"), "an unknown branch fails with a message: \(sheet.stateDetailText.prefix(70))")

            // 2. The build against itself: one build, so nothing is walked at all.
            let startedSelf = ev.started
            sheet.compare(base: .apk(vh), name: "itself")
            let selfDone = await wait("the self comparison", 60) { sheet.changeSet != nil }
            if let set = sheet.changeSet, selfDone {
                expect(set.identical && set.isUnchanged && set.summary.differing == 0 && ev.started == startedSelf && crawlers() == 0, "the build against itself answers at once with no differences and no walk (changed \(set.summary.changed), new \(set.summary.new), gone \(set.summary.gone))")
                expect(sheet.summaryLines.contains { $0 == "No differences" }, "the Summary says there are no differences")
                expect(sheet.tileCount == 0, "the Screens tab has no tiles")
                await sleep(1)
                shot("1-no-differences.png")
                expect(sheet.tour == nil && !sheet.tourIsRunning && !fm.fileExists(atPath: set.folder.appendingPathComponent("tour-head.mp4").path), "no tour is recorded when nothing differs")
            } else { expect(false, "the self comparison ended") }

            // A walk that did not finish: what only the other side reached is "not reached", never new or gone.
            do {
                let fake = base.appendingPathComponent("fake-pair", isDirectory: true)
                try? fm.createDirectory(at: fake, withIntermediateDirectories: true)
                func screen(_ id: String) -> [String: Any] { ["id": id, "activity": "a.\(id)Activity", "title": id, "depth": 0, "path": ["steps": [String]()], "captures": [String: String](), "actions": [[String: Any]]()] }
                let doc: [String: Any] = ["apk": "x.apk", "combos": [String](), "screens": [screen("s1")], "edges": [[String: Any]](), "findings": [[String: Any]](),
                                          "incomplete": ["--max-seconds 60"], "seconds": ["total": 1], "base_screens": [screen("s1"), screen("s2"), screen("s3")], "base_edges": [[String: Any]](),
                                          "compare": [["id": "s1", "base": "s1", "status": "same"], ["id": NSNull(), "base": "s2", "status": "gone"], ["id": NSNull(), "base": "s3", "status": "gone"]], "diffs": [String: Any]()]
                try? JSONSerialization.data(withJSONObject: doc).write(to: fake.appendingPathComponent("crawl.json"))
                if let cut = ChangeSet.read(fake) {
                    expect(cut.summary.gone == 0 && cut.unreached == 2 && cut.summary.same == 1 && cut.isUnchanged, "a head walk that did not finish: the base's other screens are not reached, not gone (gone \(cut.summary.gone), not reached \(cut.unreached))")
                    expect(cut.markdown(head: "h", base: "b").contains("2 not reached"), "and the summary says so")
                } else { expect(false, "the cut-short fixture reads") }
            }

            // 3. The changed build.
            let startedBefore = ev.started
            sheet.compare(base: .apk(vb), name: "seeded", baseOption: seedOption, start: "apksim://slot")
            let done = await wait("the comparison", 400) { sheet.changeSet != nil }
            expect(done && ev.started == startedBefore + 1, "the comparison of the changed build ran once")
            guard let set = sheet.changeSet, done else { finish() }
            let s = set.summary
            expect(s.changed == 1 && s.new == 0 && s.gone == 0, "exactly one screen changed, none new or gone (new \(s.new), changed \(s.changed), gone \(s.gone), same \(s.same))")
            let changed = set.differing.first
            expect(changed?.status == .changed && changed?.activity == "SlotStateActivity", "it is the slot screen (\(changed?.activity ?? "none"), \(changed?.detail ?? ""))")
            expect(changed?.diff.map { fm.fileExists(atPath: $0.path) } == true && changed?.head != nil && changed?.base != nil, "it has a head and a base capture and a difference image")
            expect((changed?.pixels ?? 0) > 0, "it counts differing pixels (\(changed?.pixels ?? 0))")
            expect(set.crashes.isEmpty, "no crash on either side")
            expect(set.reportURL.map { fm.fileExists(atPath: $0.path) } == true, "the crawler's report.html is there for Open report")

            // The sheet.
            sheet.selectTab(.summary)
            await sleep(1)
            expect(sheet.summaryText.contains("1 changed") && sheet.summaryText.contains("0 new") && sheet.summaryText.contains("0 gone"), "the header says the counts: \(sheet.summaryText)")
            expect(sheet.summaryLines.contains { $0.contains(changed?.title ?? "?") && $0.contains("px differ") }, "the Summary lists the changed screen")
            shot("2-summary.png")

            sheet.selectTab(.screens)
            await sleep(0.5)
            expect(sheet.tileCount == 1 && sheet.tileTitles.first == changed?.title, "the Screens tab lists the changed screen")
            let pictures = await wait("the three pictures", 20) { let d = sheet.detailImages; return d.base && d.head && d.diff }
            expect(pictures, "its detail shows base, head and difference")
            await sleep(0.5)
            shot("3-screens.png")
            sheet.setMode(wipe: true)
            await sleep(0.5)
            shot("3b-screens-wipe.png")
            sheet.setMode(wipe: false)

            sheet.selectTab(.map)
            let mapReady = await wait("the map", 30) { sheet.mapIsReady }
            expect(mapReady, "the Map tab holds the two walks as snapshots and has drawn them")
            await sleep(1)
            if let id = changed?.id {
                expect(sheet.mapMarks[id]?.label == "changed" && sheet.mapFrame(of: id) != nil, "the Map marks the screen as changed")
                sheet.mapSelect(id)
                expect(sheet.mapDetailLineage != nil, "selecting it fills the detail column")
                await sleep(1.5)
            }
            shot("4-map.png")

            // Export: the map on the sheet as a folder with an index.html, written with no panel.
            do {
                let out = base.appendingPathComponent("export", isDirectory: true)
                var done: Result<URL, Error>?
                sheet.exportNow(to: out) { done = $0 }
                let wrote = await wait("the export", 60) { done != nil }
                let index = out.appendingPathComponent("index.html")
                let size = (try? fm.attributesOfItem(atPath: index.path)[.size] as? Int) ?? 0
                expect(wrote && fm.fileExists(atPath: index.path) && size > 1000 && fm.fileExists(atPath: out.appendingPathComponent(MapExport.dataName).path), "Export writes index.html (\(size) bytes) and \(MapExport.dataName)")
                let data = (try? String(contentsOf: out.appendingPathComponent(MapExport.dataName), encoding: .utf8)) ?? ""
                expect(data.contains(changed?.title ?? "?") && ((try? fm.contentsOfDirectory(atPath: out.appendingPathComponent("img").path)) ?? []).count >= 2, "the export names the changed screen and holds its pictures")
                expect(sheet.exportStatus.hasPrefix("Exported to"), "the sheet says so: \(sheet.exportStatus.suffix(40))")
            }

            sheet.selectTab(.live)
            await sleep(0.5)
            shot("6-live.png")

            // Copy summary.
            let md = sheet.markdown ?? ""
            expect(md.contains(changed?.title ?? "?") && md.contains("1 changed") && md.contains("~ "), "Copy summary's Markdown names the screen: \(md.split(separator: "\n").dropFirst(2).first.map(String.init) ?? "")")
            sheet.copySummary()
            expect(NSPasteboard.general.string(forType: .string) == md, "Copy summary puts it on the clipboard")

            // The change tour: recorded by itself after a comparison with differences.
            sheet.selectTab(.video)
            let toured = await wait("the change tour", 400) { sheet.tour != nil }
            expect(toured, "the change tour finished")
            if let tour = sheet.tour {
                expect(tour.skipped == nil, "the tour was not skipped\(tour.skipped.map { ": " + $0 } ?? "")")
                for (name, file) in [("head", tour.head), ("base", tour.base)] {
                    guard let file else { expect(false, "the \(name) clip is there"); continue }
                    let asset = AVURLAsset(url: file)
                    let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                    let duration = (try? await asset.load(.duration).seconds) ?? 0
                    let playable = (try? await asset.load(.isPlayable)) ?? false
                    expect(file.pathExtension == "mp4" && !tracks.isEmpty && duration > 1 && playable, "tour-\(name).mp4 plays: a video track, \(String(format: "%.1f", duration)) s")
                    let chapters = tour.chapters(of: file)
                    expect(chapters.count == set.differing.count && chapters.first?.title == changed?.title, "tour-\(name).mp4 has a chapter per changed screen (\(chapters.map(\.title).joined(separator: ", ")))")
                }
                expect(tour.stops.count == 1 && tour.stops.first?.head == true && tour.stops.first?.base == true, "the tour reached the screen in both builds")
                _ = await wait("the players", 20) { sheet.hasPlayers }
                await sleep(2)
                shot("5-video.png")
            }

            // The same pair again: cached, nothing runs.
            let started = ev.started
            sheet.compare(base: .apk(vb), name: "seeded", baseOption: seedOption, start: "apksim://slot")
            let again = await wait("the cached comparison", 30) { sheet.changeSet != nil }
            expect(again && ev.started == started && sheet.changeSet?.summary.changed == 1, "a pair already compared answers at once, without a run")
            let cachedTour = await wait("the cached tour", 30) { sheet.tour != nil }
            expect(cachedTour && sheet.tour?.head != nil, "and its tour is kept with the pair")

            // A tour cancelled mid-recording leaves nothing running or half-written, and a tour can be recorded again.
            var tourPIDs: [Int32] = []
            func hidden() -> Int { tourPIDs.filter { kill($0, 0) == 0 }.count }
            func tourFiles() -> [String] { ((try? fm.contentsOfDirectory(atPath: set.folder.path)) ?? []).filter { $0.hasPrefix("tour-") || $0.hasSuffix(".part") } }
            sheet.recordTour(force: true)
            let up = await wait("both hidden simulators", 120) { tourPIDs = sheet.tourProcessIDs.isEmpty ? tourPIDs : sheet.tourProcessIDs; return tourPIDs.count >= 2 && hidden() >= 2 }
            expect(up && sheet.tourIsRunning, "a tour that starts has two hidden simulators running (\(hidden()))")
            await sleep(3)   // recording
            sheet.cancelTour()
            let ended = await wait("the cancelled tour to end", 60) { !sheet.tourIsRunning }
            let gone = await wait("the hidden simulators to quit", 30) { hidden() == 0 }
            expect(ended && gone, "cancelling a tour mid-recording ends it and both hidden apksim processes (\(hidden()) left)")
            expect(tourFiles().isEmpty && sheet.tour == nil, "and leaves no .part file or clip behind (\(tourFiles().joined(separator: ", ")))")
            func tourLogs() -> [String] { ((try? fm.contentsOfDirectory(atPath: Engine.shared.logs.path)) ?? []).filter { $0.hasPrefix("tour-") } }
            _ = await wait("the logs to go", 20) { tourLogs().isEmpty }   // removed once each process has exited
            let logsLeft = tourLogs()
            expect(logsLeft.isEmpty, "the tour's simulator logs are removed (\(logsLeft.count) left)")
            sheet.recordTour(force: true)
            let again2 = await wait("the tour again", 400) { sheet.tour != nil }
            expect(again2 && sheet.tour?.skipped == nil && sheet.tour?.head != nil && sheet.tour?.base != nil, "a tour can be recorded again after a cancelled one")
            expect(Set(tourFiles()) == ["tour-head.mp4", "tour-head.chapters.json", "tour-base.mp4", "tour-base.chapters.json"], "and its files are the final ones alone (\(tourFiles().sorted().joined(separator: ", ")))")
            if let hf = sheet.tour?.head { expect(((try? await AVURLAsset(url: hf).load(.duration).seconds) ?? 0) > 1, "and it plays") }

            // A rebuild since the comparison: reopening the sheet does not show the old build's result.
            if let v3 = variant(), let b3 = store.record(apk: v3, source: .local, sha: a.head, ref: a.branch, dirty: false, date: Date().addingTimeInterval(5)) {
                sessions.adopt(b3, forWorktree: a.worktree.path)
                if let fresh = row() { sheet.open(session: fresh, compare: false) }
                let reset = await wait("the new build to be compared", 30) { sheet.changeSet == nil && sheet.run?.head?.key == b3.key }
                expect(reset, "reopening after a rebuild drops the old comparison and compares the new build (\(sheet.stateTitleText))")
            } else { expect(false, "a third build could be filed") }

            // Against the base branch: held back until the project has a map of it, then answered from that map with
            // only the screens this branch's files reach walked. Main's map is made here by walking the same app once
            // and writing a text into one screen of it that the branch's build does not have.
            fromMain: do {
                guard let python = SnapshotRun.python() else { expect(false, "Python 3 is there for the base branch's walk"); break fromMain }
                let support = await Task.detached { CrawlRun.support(python: python) }.value
                guard support.seed, support.recordDeps else { say("skipped: this engine's crawler cannot start from an earlier walk"); break fromMain }
                let before = ev.started
                guard let s0 = row() else { expect(false, "the row is there"); break fromMain }
                sheet.open(session: s0, compare: false)
                sheet.compare(base: .baseBranch)
                let held = await wait("the comparison to be held", 30) { sheet.stateTitleText.contains("has not been walked yet") }
                expect(held && sheet.changeSet == nil && ev.started == before && sheet.run?.isActive == false,
                       "with no map of main the comparison is held and nothing is walked (\(sheet.stateTitleText): \(sheet.stateDetailText.prefix(90)))")
                shot("7-held.png")

                // Main's one walk: the whole app (a walk cut at a depth leaves its last screens with no record of what
                // they depend on, and those are walked again every time). A build of its own: `vb` is filed with no commit.
                ev.budget = Evidence.Budget(depth: 0, seconds: 300, jobs: 2)
                guard let vm = variant() else { expect(false, "main's build is made"); break fromMain }
                let mainWalk = base.appendingPathComponent("main-walk", isDirectory: true)
                var cs = CrawlRun.Settings()
                cs.depth = ev.budget.depth; cs.seconds = ev.budget.seconds; cs.jobs = 2; cs.appearances = ["light"]; cs.recordDeps = true
                cs.engineOptions = ["--data-slots", SlotClone.freshName(prefix: "evg")]
                let crawl = CrawlRun(python: python, apk: vm, out: mainWalk, settings: cs)
                var outcome: CrawlRun.Outcome?
                crawl.onFinish = { outcome = $0 }
                let t0 = Date()
                crawl.start()
                _ = await wait("main's walk", 600) { outcome != nil }
                let fullSeconds = Date().timeIntervalSince(t0)
                guard case .finished? = outcome, let data = try? Data(contentsOf: mainWalk.appendingPathComponent("crawl.json")),
                      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], var list = json["screens"] as? [[String: Any]] else {
                    expect(false, "main's walk finished"); break fromMain
                }
                let startSources = Set(((json["start_deps"] as? [String: Any])?["sources"] as? [String]) ?? [])
                func sources(_ sc: [String: Any]) -> [String] { ((sc["deps"] as? [String: Any])?["sources"] as? [String]) ?? [] }
                var uses: [String: Int] = [:]
                for sc in list { for f in sources(sc) where !startSources.contains(f) { uses[f, default: 0] += 1 } }
                // The file on the fewest screens: those are the ones the branch's walk must redo.
                guard let file = uses.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }).first?.key, let at = list.firstIndex(where: { sources($0).contains(file) }) else {
                    say("skipped: no source file of the test app is outside app start"); break fromMain
                }
                let reached = uses[file] ?? 1
                let target = (list[at]["id"] as? String) ?? "", targetTitle = (list[at]["title"] as? String) ?? ""
                list[at]["texts"] = ((list[at]["texts"] as? [String]) ?? []) + ["Only on main"]
                json["screens"] = list
                try? JSONSerialization.data(withJSONObject: json).write(to: mainWalk.appendingPathComponent("crawl.json"))
                let profile = ev.walkProfiles(worktree: s0.worktree.path, withData: false)[0]
                guard let mainBuild = store.record(apk: vm, source: .local, sha: firstSha, ref: "main", dirty: false, date: Date()) else { expect(false, "main's build is filed"); break fromMain }
                let root = ev.store.root, engine = Engine.shared.version, spaces = sessions.workspaces
                let filed = await Task.detached { await History.filed(walk: mainWalk, build: mainBuild, profile: profile, candidates: spaces, stateRoot: root, engine: engine) }.value
                expect(filed != nil, "main's walk (\(list.count) screens, \(Int(fullSeconds)) s) is the project's map of main")

                // The branch changes the one file that screen depends on, and is built again.
                let changedFile = wt.appendingPathComponent("app/src/main/java/" + file)
                try? fm.createDirectory(at: changedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "// changed\n".write(to: changedFile, atomically: true, encoding: .utf8)
                _ = git(["add", "."], in: wt); _ = git(["commit", "-q", "-m", "third"], in: wt)
                guard let sha3 = git(["rev-parse", "HEAD"], in: wt)?.trimmingCharacters(in: .whitespacesAndNewlines), let v4 = variant(),
                      let b4 = store.record(apk: v4, source: .local, sha: sha3, ref: "feature", dirty: false, date: Date().addingTimeInterval(10)) else {
                    expect(false, "the branch's new build is filed"); break fromMain
                }
                sessions.adopt(b4, forWorktree: s0.worktree.path)
                guard let s1 = row() else { break fromMain }
                sheet.open(session: s1, compare: false)
                let t1 = Date()
                sheet.compare(base: .baseBranch)
                let done = await wait("the comparison with main's map", 900) { sheet.changeSet != nil || sheet.stateTitleText.contains("Could not") }
                let quickSeconds = Date().timeIntervalSince(t1)
                guard done, let set = sheet.changeSet else { expect(false, "the comparison with main's map finished (\(sheet.stateTitleText): \(sheet.stateDetailText.prefix(160)))"); break fromMain }
                let note = ev.entry(of: s1.worktree.path)?.impact
                let noRecord = list.filter { $0["deps"] == nil }.count
                expect(note?.full == false && (note?.walked ?? 0) >= reached && (note?.walked ?? 99) <= reached + noRecord && (note?.walked ?? 99) < list.count && note?.total == list.count,
                       "the branch's walk walked the \(reached) screen(s) \((file as NSString).lastPathComponent) is on and at most the \(noRecord) main's walk has no record for, of \(list.count) (\(note.map { "\($0.walked) of \($0.total)\($0.full ? ", full: " + ($0.reason ?? "") : "")" } ?? "no note")), \(String(format: "%.1f", quickSeconds)) s against \(Int(fullSeconds)) s for main's")
                // The screens the file is on were walked again; the app's own noise may make more of them differ than
                // the one written into, but nothing that was carried can.
                let differing = set.differing
                let onFile = Set(list.filter { sources($0).contains(file) }.compactMap { $0["id"] as? String })
                let mine = differing.first { $0.baseID == target }
                // A carried screen can differ only in where a control leads: one of its controls led to a screen that was
                // walked again and is now read as another (the test app's Bind does that from run to run).
                expect(mine?.status == .changed && differing.allSatisfy { c in c.baseID.map(onFile.contains) ?? true || set.change(of: c)?.reasons == [.routes] },
                       "the screen written into differs, and a carried screen only in where a control leads (\(differing.map { "\($0.title) \($0.status.word) \($0.baseID ?? "-")" }.joined(separator: ", ")); expected \(targetTitle) \(target); the file is on \(onFile.sorted().joined(separator: " ")))")
                expect(set.baseline?.contains("main at " + String(firstSha.prefix(7))) == true, "the header says what it was compared with: \(set.baseline ?? "nothing")")
                sheet.selectTab(.screens)
                try? await Task.sleep(nanoseconds: 800_000_000)
                expect(sheet.groupTitles.contains("Changed \(differing.filter { $0.status == .changed }.count)"), "the Screens tab groups them: \(sheet.groupTitles.joined(separator: ", "))")
                if let mine { sheet.selectScreen(mine.id) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                let notes = sheet.detailNotesText
                expect(notes.contains("Only on main") && notes.contains("Walked again because") && notes.contains((file as NSString).lastPathComponent),
                       "its detail says what changed and why it was walked: \(notes.replacingOccurrences(of: "\n", with: " | "))")
                shot("8-from-main.png")

                // The same comparison in the whole app: the Map tab opens on the changes; unfolded, the screens that did
                // not change step back and the view is on the place where the changed ones stand.
                sheet.selectTab(.map)
                let drawn = await wait("the map of the comparison with main", 30) { sheet.mapIsReady }
                await sleep(1)
                let nav = sheet.mapHost.navigator
                // A small app's changes and their neighbours are the whole map: nothing is folded and there is nothing to unfold.
                let small = nav.plan?.folded == 0
                expect(drawn && (small ? nav.surface.spotlight : nav.regions.isEmpty && nav.foldTitle.contains("show in the whole app")),
                       small ? "the Map tab of a small app opens on the whole map, with nothing to unfold" : "the Map tab opens on the changes, with the rest one click away (\(nav.foldTitle))")
                shot("9-map-changes.png")
                if !small { nav.toggleFold(); await sleep(1.2) }
                let frames = nav.surface.changedFrames
                let view = nav.surface.enclosingScrollView?.contentView.bounds ?? .zero
                expect(nav.surface.spotlight && frames.count == differing.count && !nav.regions.isEmpty && nav.regions.allSatisfy { r in frames.contains { r.contains($0) } }
                       && view.intersects(nav.regions[0]) && !nav.regionTitle.isEmpty,
                       "in the whole app the \(frames.count) changed screens stand in \(nav.regions.count) place(s) and the view is on the first (\(nav.regionTitle))")
                shot("10-map-whole-app.png")

                // The session's row counts the changes against main's map; a click on the count opens the comparison.
                let counted = await wait("the row's count", 20) { ev.entry(of: s1.worktree.path)?.changed != nil }
                func buttons(_ v: NSView?) -> [NSButton] { guard let v else { return [] }; return (v as? NSButton).map { [$0] } ?? v.subviews.flatMap { buttons($0) } }
                let count = buttons(ev.badge(for: s1)).first { $0.title.hasSuffix("changed") }
                expect(counted && ev.entry(of: s1.worktree.path)?.changed == differing.count && count?.title == "\(differing.count) changed",
                       "the row says \(count?.title ?? "nothing") (\(ev.entry(of: s1.worktree.path)?.changedWords ?? "no words"))")
                sheet.close()
                await sleep(0.5)
                count?.performClick(nil)
                let reopened = await wait("the comparison from the row", 20) { sheet.isOpen && sheet.changeSet != nil }
                expect(reopened && sheet.session?.worktree.path == s1.worktree.path, "a click on it opens the comparison")

                // A build file changes too: nothing says which screens it reaches, so no screen is walked for it, the
                // walk is not a full one, and the comparison says what it could not trace.
                try? "android { }\n".write(to: wt.appendingPathComponent("app/build.gradle.kts"), atomically: true, encoding: .utf8)
                _ = git(["add", "."], in: wt); _ = git(["commit", "-q", "-m", "fourth"], in: wt)
                guard let sha4 = git(["rev-parse", "HEAD"], in: wt)?.trimmingCharacters(in: .whitespacesAndNewlines), let v5 = variant(),
                      let b5 = store.record(apk: v5, source: .local, sha: sha4, ref: "feature", dirty: false, date: Date().addingTimeInterval(20)) else {
                    expect(false, "the branch's build with a build file changed is filed"); break fromMain
                }
                sessions.adopt(b5, forWorktree: s1.worktree.path)
                guard let s2 = row() else { break fromMain }
                sheet.open(session: s2, compare: false)
                sheet.compare(base: .baseBranch)
                let again = await wait("the comparison with a build file changed", 900) { (sheet.changeSet != nil && sheet.run?.head?.key == b5.key) || sheet.stateTitleText.contains("Could not") }
                guard again, let set2 = sheet.changeSet else { expect(false, "that comparison finished (\(sheet.stateTitleText): \(sheet.stateDetailText.prefix(160)))"); break fromMain }
                let note2 = ev.entry(of: s2.worktree.path)?.impact
                expect(note2?.full == false && (note2?.walked ?? 99) < list.count && set2.unplaced.count == 1 && set2.unplaced[0].contains("build.gradle.kts"),
                       "a build file beside it is not a full walk (\(note2.map { "\($0.walked) of \($0.total)" } ?? "no note")) and is named as not traced: \(set2.unplaced.joined(separator: "; "))")
                sheet.selectTab(.summary)
                await sleep(0.6)
                func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap { texts($0) } }
                let words = texts(sheet)
                expect(words.contains { $0.contains("NOT TRACED TO SCREENS") } && words.contains { $0.contains("build.gradle.kts") } && sheet.summaryText.contains("1 change not traced to screens"),
                       "the Summary lists it and the header counts it: \(sheet.summaryText)")
                shot("11-not-traced.png")

                // Another build of a commit that has its map: an automatic walk takes the stored map and walks nothing.
                if let v6 = variant(), let b6 = store.record(apk: v6, source: .local, sha: sha4, ref: "feature", dirty: false, date: Date().addingTimeInterval(30)) {
                    let t6 = Date()
                    ev.buildArrived(worktree: s2.worktree.path, build: b6, auto: .onBuild, withData: false)
                    var most = 0
                    let taken = await wait("the stored map to be taken", 60) {
                        most = max(most, crawlers())
                        if let e = ev.entry(of: s2.worktree.path), e.key == b6.key, case .done = e.status { return true }
                        return false
                    }
                    let e6 = ev.entry(of: s2.worktree.path)
                    expect(taken && most == 0 && e6?.impact?.reason?.hasPrefix("this commit's map was already there") == true,
                           "another build of a walked commit takes its stored map in \(String(format: "%.1f", Date().timeIntervalSince(t6))) s with no walk (\(e6?.impact?.reason ?? "no note"); crawlers seen: \(most))")
                } else { expect(false, "another build of the commit is filed") }
            }

            let lastLogs = await wait("the last tour's logs to go", 20) { ((try? fm.contentsOfDirectory(atPath: Engine.shared.logs.path)) ?? []).allSatisfy { !$0.hasPrefix("tour-") } }
            expect(lastLogs, "the last tour's logs are gone too, so none is left for the next run")
            let leftovers = hidden()
            expect(leftovers == 0 && crawlers() == 0, "no hidden simulator or crawler is left running (\(leftovers))")
            finish()
        }
    }
}
