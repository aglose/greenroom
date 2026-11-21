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
            ev.budget = Evidence.Budget(depth: 1, seconds: 60, jobs: 2)
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

            // 2. The build against itself.
            sheet.compare(base: .apk(vh), name: "itself")
            let selfDone = await wait("the self comparison", 300) { sheet.changeSet != nil }
            if let set = sheet.changeSet, selfDone {
                expect(set.isUnchanged && set.summary.same > 0 && set.summary.differing == 0, "the build against itself differs on no screen (same \(set.summary.same), changed \(set.summary.changed), new \(set.summary.new), gone \(set.summary.gone))")
                expect(sheet.summaryLines.contains { $0 == "No differences" }, "the Summary says there are no differences")
                expect(sheet.tileCount == 0, "the Screens tab has no tiles")
                await sleep(1)
                shot("1-no-differences.png")
                expect(sheet.tour == nil && !sheet.tourIsRunning && !fm.fileExists(atPath: set.folder.appendingPathComponent("tour-head.mp4").path), "no tour is recorded when nothing differs")
            } else { expect(false, "the self comparison ended") }

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
            await sleep(1)
            if let id = changed?.id {
                expect(sheet.mapMarks[id]?.label == "changed" && sheet.canvas.frame(of: id) != nil, "the Map marks the screen as changed")
                sheet.canvas.select(id, reveal: false)
                await sleep(1.5)
            }
            shot("4-map.png")

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

            let leftovers = (run("/usr/bin/pgrep", ["-f", "changes-check/engine-state.*--data-slots"]) ?? "").split(separator: "\n").count
            expect(leftovers == 0 && crawlers() == 0, "no hidden simulator or crawler is left running (\(leftovers))")
            finish()
        }
    }
}
