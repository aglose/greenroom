import CoreGraphics
import Foundation
import ImageIO

/// `Greenroom --map-impact-check DIR [APK]`: walking only what changed (packages I1, I2), headless. A temporary git
/// repository with an Android-shaped tree (a base commit, two more on main, and one branch commit per other case) and a
/// fixture app of 15 screens whose snapshot records what each depends on. `MapImpact` on each change: a one-file Kotlin
/// change walks exactly its 2 of 15 screens, a layout its screen, a string the screens that use it; the manifest, a
/// Gradle file, the Application class and a source file no screen names walk everything, with the reason in words; a
/// README walks nothing. The seed folder written from a snapshot reads back to the same snapshot; a planted miss (a full
/// walk finds a carried screen changed) is reported and its directory becomes a full-walk pattern; the plan of a walk on
/// main seeds it. Then a live run: a full walk with deps, then one seeded with one screen named, with both times, and the
/// second equal to the first apart from origin. The crawler is the engine's when `GREENROOM_ENGINE` names one with
/// `--seed` and `--record-deps` and APK is given; otherwise a stand-in that imitates its arguments and output.
enum MapImpactCheck {
    // MARK: The fixture app

    struct Model {
        let id: String, activity: String, title: String, depth: Int, parent: String?, steps: [String]
        let sources: [String], resources: [String], texts: [String]
        let color: (Int, Int, Int)
        var edges: [(action: String, cmd: String, to: String)] = []
    }

    static let pkg = "com/example/trips/"
    static let src = "app/src/main/java/com/example/trips/"
    static let startDeps = MapSnapshot.Deps(classes: ["com.example.trips.TripsApp"], sources: [pkg + "TripsApp.kt"], resources: ["mipmap/ic_launcher", "style/Theme.Trips"])

    /// 15 screens. TripsActivity.kt is on exactly two (1 and 2); layout/trip_row on one (3); string/trip_title on two (3, 4).
    static func models() -> [Model] {
        let rows: [(String, String, Int, Int?, [String], [String])] = [
            ("TripsActivity", "Trips", 0, nil, ["TripsActivity.kt", "TripsAdapter.kt"], ["layout/activity_trips", "string/trips_title"]),
            ("TripsActivity", "Trips: upcoming", 1, 0, ["TripsActivity.kt", "FilterSheet.kt"], ["layout/filter_sheet"]),
            ("TripDetailActivity", "Trip", 1, 0, ["TripDetailActivity.kt"], ["layout/trip_row", "string/trip_title"]),
            ("TripDetailActivity", "Trip map", 2, 2, ["TripMapFragment.kt"], ["layout/trip_map", "string/trip_title"]),
            ("SettingsActivity", "Settings", 1, 0, ["SettingsActivity.kt"], ["xml/preferences", "string/settings_title"]),
            ("ProfileActivity", "Profile", 1, 0, ["ProfileActivity.kt"], ["layout/profile", "drawable/avatar"]),
            ("BookingActivity", "Book", 1, 0, ["BookingActivity.kt"], ["layout/booking", "color/accent"]),
            ("BookingActivity", "Book: dates", 2, 6, ["BookingActivity.kt", "DatePicker.kt"], ["layout/dates"]),
            ("PaymentActivity", "Pay", 2, 6, ["PaymentActivity.kt"], ["layout/payment", "dimen/card_margin"]),
            ("HelpActivity", "Help", 1, 0, ["HelpActivity.kt"], ["layout/help", "raw/faq"]),
            ("AboutActivity", "About", 2, 9, ["AboutActivity.kt"], ["layout/about", "string/version_name"]),
            ("SearchActivity", "Search", 1, 0, ["SearchActivity.kt"], ["layout/search", "menu/search"]),
            ("SearchActivity", "Search: results", 2, 11, ["SearchActivity.kt", "ResultsAdapter.kt"], ["layout/results"]),
            ("InboxActivity", "Inbox", 1, 0, ["InboxActivity.kt"], ["layout/inbox", "plurals/messages"]),
            ("InboxActivity", "Message", 2, 13, ["MessageActivity.kt"], ["layout/message", "anim/slide_in"]),
        ]
        var out: [Model] = []
        for (i, r) in rows.enumerated() {
            let id = "\(r.0)-\(String(format: "%02d", i + 1))a5e9"
            let parent = r.3.map { out[$0].id }
            let steps = r.3.map { (out[$0].steps) + ["tap-text \(r.1)"] } ?? []
            out.append(Model(id: id, activity: "com.example.trips." + r.0, title: r.1, depth: r.2, parent: parent, steps: steps,
                             sources: r.4.map { pkg + $0 }, resources: r.5, texts: [r.1, "screen \(i + 1)"],
                             color: ((i * 53) % 256, (i * 97 + 40) % 256, (i * 31 + 90) % 256)))
        }
        for i in out.indices {
            for (n, j) in out.indices.filter({ out[$0].parent == out[i].id }).enumerated() { out[i].edges.append(("Open \(out[j].title)", "tap-text \(out[j].title) \(n)", out[j].id)) }
            out[i].edges.append(("Back", "back", i == 0 ? "EXIT" : out[i].parent!))
        }
        return out
    }

    static func png(_ url: URL, _ c: (Int, Int, Int)) {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    /// A walk's folder of the fixture app, as the crawler with `--record-deps` writes it. `carried`: screens marked carried;
    /// `recolor`: screens whose capture differs (a planted change).
    static func writeWalk(_ folder: URL, models: [Model], carried: Set<String> = [], recolor: Set<String> = [], deps: Bool = true) {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder.appendingPathComponent("screens"), withIntermediateDirectories: true)
        var screens: [[String: Any]] = [], edges: [[String: Any]] = []
        for m in models {
            let rel = "screens/\(m.id)-light.png"
            png(folder.appendingPathComponent(rel), recolor.contains(m.id) ? (255 - m.color.0, m.color.1, m.color.2) : m.color)
            var s: [String: Any] = ["id": m.id, "activity": m.activity, "title": m.title, "depth": m.depth, "parent": m.parent ?? NSNull(),
                                    "path": ["steps": m.steps], "captures": ["light": rel], "texts": m.texts, "settled": true,
                                    "origin": carried.contains(m.id) ? "carried" : "walked"]
            if deps { s["deps"] = ["classes": m.sources.map { $0.replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ".kt", with: "") }, "sources": m.sources, "resources": m.resources] }
            screens.append(s)
            for e in m.edges { edges.append(["from": m.id, "action": e.action, "cmd": e.cmd, "to": e.to]) }
        }
        var json: [String: Any] = ["combos": ["light"], "screens": screens, "edges": edges, "findings": [], "incomplete": [], "seconds": ["total": 42.5]]
        if deps { json["start_deps"] = ["classes": startDeps.classes, "sources": startDeps.sources, "resources": startDeps.resources] }
        try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("crawl.json"))
    }

    /// The model as the stand-in crawler's "APK".
    static func modelJSON(_ models: [Model]) -> Data {
        let screens: [[String: Any]] = models.map { m in
            ["id": m.id, "activity": m.activity, "title": m.title, "depth": m.depth, "parent": m.parent ?? NSNull(), "steps": m.steps, "texts": m.texts,
             "color": [m.color.0, m.color.1, m.color.2],
             "deps": ["classes": m.sources.map { $0.replacingOccurrences(of: "/", with: ".").replacingOccurrences(of: ".kt", with: "") }, "sources": m.sources, "resources": m.resources],
             "edges": m.edges.map { ["action": $0.action, "cmd": $0.cmd, "to": $0.to] }]
        }
        let start: [String: Any] = ["classes": startDeps.classes, "sources": startDeps.sources, "resources": startDeps.resources]
        return (try? JSONSerialization.data(withJSONObject: ["screens": screens, "start_deps": start], options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: The repository

    static let files: [String: String] = [
        "settings.gradle.kts": "include(\":app\")\n",
        "build.gradle.kts": "plugins { }\n",
        "app/build.gradle.kts": "android { namespace = \"com.example.trips\" }\n",
        "gradle/libs.versions.toml": "[versions]\nkotlin = \"2.0.0\"\n",
        "app/src/main/AndroidManifest.xml": "<manifest>\n  <application android:name=\".TripsApp\" android:theme=\"@style/Theme.Trips\"/>\n</manifest>\n",
        "app/src/main/res/layout/trip_row.xml": "<LinearLayout/>\n",
        "app/src/main/res/layout/activity_trips.xml": "<FrameLayout/>\n",
        "app/src/main/res/values/strings.xml": """
            <?xml version="1.0" encoding="utf-8"?>
            <resources>
                <string name="trips_title">Trips</string>
                <string name="trip_title">Your trip</string>
                <string name="settings_title">Settings</string>
            </resources>

            """,
        "app/src/main/res/values/themes.xml": """
            <resources>
                <style name="Theme.Trips" parent="Theme.Material3.Light">
                    <item name="colorPrimary">#336699</item>
                </style>
                <style name="Widget.Trips.Row">
                    <item name="android:padding">8dp</item>
                </style>
            </resources>

            """,
        "app/src/test/java/com/example/trips/TripsTest.kt": "class TripsTest\n",
        "README.md": "# Trips\n",
    ]

    static func run(dir: URL, apk: URL?) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-impact: \(good ? "ok  " : "FAIL") \(what)") }
        func finish() -> Never { print("[greenroom] map-impact check: \(ok ? "PASS" : "FAIL")"); exit(ok ? 0 : 1) }
        func sync<T>(_ body: @escaping () async -> T) -> T {
            var out: T?
            let wait = DispatchSemaphore(value: 0)
            Task.detached { out = await body(); wait.signal() }
            wait.wait()
            return out!
        }
        let fm = FileManager.default
        let base = dir.resolvingSymlinksInPath().appendingPathComponent("map-impact-check", isDirectory: true)
        try? fm.removeItem(at: base.appendingPathComponent("repo"))
        try? fm.removeItem(at: base.appendingPathComponent("state"))
        try? fm.removeItem(at: base.appendingPathComponent("live"))
        try? fm.removeItem(at: base.appendingPathComponent("walks"))
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let models = models()
        let ids = models.map(\.id)

        // 1. The repository: a base, then cases.
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            p.currentDirectoryURL = repo
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        func write(_ rel: String, _ text: String) {
            let url = repo.appendingPathComponent(rel)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        func commit(_ message: String) -> String {
            _ = git(["add", "-A"]); _ = git(["commit", "-q", "--allow-empty", "-m", message])
            return git(["rev-parse", "HEAD"]) ?? ""
        }
        guard git(["init", "-q", "-b", "main"]) != nil else { expect(false, "a repository was made (is /usr/bin/git there?)"); finish() }
        for (rel, text) in files { write(rel, text) }
        var sources = Set(models.flatMap(\.sources).map { ($0 as NSString).lastPathComponent }); sources.insert("TripsApp.kt")
        for f in sources { write(src + f, "package com.example.trips\n\nclass \((f as NSString).deletingPathExtension)\n") }
        let c0 = commit("base")
        // Main: a one-file Kotlin change, then a string's value.
        write(src + "TripsActivity.kt", "package com.example.trips\n\nclass TripsActivity { val x = 1 }\n")
        let c1 = commit("kotlin")
        write("app/src/main/res/values/strings.xml", files["app/src/main/res/values/strings.xml"]!.replacingOccurrences(of: "Your trip", with: "This trip"))
        let c2 = commit("string")
        // The other cases, each one commit on a branch from the base.
        func branch(_ name: String, _ change: () -> Void) -> String {
            _ = git(["checkout", "-q", "--detach", c0])
            change()
            let c = commit(name)
            _ = git(["checkout", "-q", "main"])
            return c
        }
        let layout = branch("layout") { write("app/src/main/res/layout/trip_row.xml", "<LinearLayout android:padding=\"4dp\"/>\n") }
        let manifest = branch("manifest") { write("app/src/main/AndroidManifest.xml", "<manifest>\n  <application android:name=\".TripsApp\" android:label=\"Trips\"/>\n</manifest>\n") }
        let gradle = branch("gradle") { write("app/build.gradle.kts", "android { namespace = \"com.example.trips\"; compileSdk = 35 }\n") }
        let app = branch("application") { write(src + "TripsApp.kt", "package com.example.trips\n\nclass TripsApp : Application()\n") }
        let orphan = branch("unmapped") { write(src + "Orphan.kt", "package com.example.trips\n\nclass Orphan\n") }
        let readme = branch("readme") { write("README.md", "# Trips\n\nNow with words.\n"); write("app/src/test/java/com/example/trips/TripsTest.kt", "class TripsTest { }\n") }
        let styleItem = branch("style item") { write("app/src/main/res/values/themes.xml", files["app/src/main/res/values/themes.xml"]!.replacingOccurrences(of: "8dp", with: "12dp")) }
        expect(![c0, c1, c2, layout, manifest, gradle, app, orphan, readme, styleItem].contains(""), "a repository with an Android-shaped tree: base, 2 more commits on main, 7 branch commits")

        // 2. The baseline: the fixture walk at the base, with deps.
        let profile = MapProfile()
        let walks = base.appendingPathComponent("walks", isDirectory: true)
        let stateRoot = base.appendingPathComponent("state", isDirectory: true)
        let store = History.store(stateRoot: stateRoot, workspace: repo)
        let full0 = walks.appendingPathComponent("full-c0")
        writeWalk(full0, models: models)
        guard let snap0 = store.importWalk(full0, commit: c0, tree: git(["rev-parse", c0 + "^{tree}"]) ?? "", profile: profile, engine: "e1", walked: Date()) else {
            expect(false, "the fixture walk was imported"); finish()
        }
        expect(snap0.screens.count == 15 && snap0.screens.allSatisfy { $0.deps != nil && !($0.deps!.sources.isEmpty) } && snap0.startDeps == startDeps,
               "the fixture snapshot has 15 screens, each with its deps, and the app start's")

        func decide(_ head: String, from: String? = nil, baseline: MapSnapshot? = nil, patterns: [String] = []) -> MapImpact.Decision {
            guard let d = sync({ await MapImpact.changes(base: from ?? c0, head: head, in: repo) }) else { return .full("git failed") }
            return MapImpact.decide(MapImpact.Input(baseline: baseline ?? snap0, changes: d.changes, valueDiff: d.valueDiff, engine: "e1", profile: profile,
                                                    fullWalkPatterns: patterns))
        }
        func words(_ d: MapImpact.Decision) -> String {
            switch d {
            case .full(let why): return "full: " + why
            case .screens(let ids, _): return "\(ids.count) screen(s): " + ids.joined(separator: ", ")
            }
        }
        func screens(_ d: MapImpact.Decision) -> [String]? { if case .screens(let s, _) = d { return s } else { return nil } }
        func full(_ d: MapImpact.Decision) -> String? { if case .full(let w) = d { return w } else { return nil } }

        let kotlin = decide(c1)
        expect(screens(kotlin) == [ids[0], ids[1]], "a one-file Kotlin change (TripsActivity.kt) walks exactly its 2 of 15 screens (\(words(kotlin)))")
        if case .screens(_, let why) = kotlin { expect(why[ids[0]] == ["TripsActivity.kt changed"], "and says why: \(why[ids[0]] ?? [])") }
        let lay = decide(layout)
        expect(screens(lay) == [ids[2]], "a layout change (trip_row.xml) walks its screen (\(words(lay)))")
        let str = decide(c2, from: c1)
        expect(screens(str) == [ids[2], ids[3]], "a string's value (trip_title) walks the 2 screens that use it (\(words(str)))")
        let man = decide(manifest)
        expect(full(man) == "the manifest changed", "a manifest change walks everything: \(words(man))")
        let gra = decide(gradle)
        expect(full(gra) == "build files changed", "a Gradle change walks everything: \(words(gra))")
        let ap = decide(app)
        expect(full(ap)?.hasPrefix("app start changed") == true, "an Application-class change walks everything: \(words(ap))")
        let orp = decide(orphan)
        expect(full(orp)?.hasPrefix("a changed source file is on no screen") == true && full(orp)!.contains("Orphan.kt"), "a source file no screen names walks everything: \(words(orp))")
        let rd = decide(readme)
        expect(screens(rd) == [], "a README and a unit test change walk nothing (\(words(rd)))")
        let sty = decide(styleItem)
        expect(full(sty)?.contains("names no resource") == true, "a style's item (no name of its own on the line) walks everything: \(words(sty))")
        var noDeps = snap0; noDeps.startDeps = nil; for i in noDeps.screens.indices { noDeps.screens[i].deps = nil }
        expect(full(decide(c1, baseline: noDeps)) == "the last walk did not record what its screens depend on", "a baseline with no deps walks everything")
        var unreliable = snap0; unreliable.depsUnreliable = "probes lost"
        expect(full(decide(c1, baseline: unreliable))?.contains("cannot be trusted (probes lost)") == true, "a baseline whose deps cannot be trusted walks everything")
        var older = snap0; older.engine = "e0"
        expect(screens(decide(c1, baseline: older)) == screens(kotlin), "a baseline walked by another engine is kept: the same 2 screens are walked")
        // A branch's build: what cannot be traced is named, what can is walked.
        func lenient(_ changes: [MapImpact.FileChange]) -> (decision: MapImpact.Decision, unplaced: [String]) {
            MapImpact.decideLenient(MapImpact.Input(baseline: snap0, changes: changes, engine: "e1", profile: profile))
        }
        let kotlinFile = "app/src/main/java/com/example/trips/TripsActivity.kt"
        let mixed = lenient([.init(status: "M", path: "app/build.gradle.kts"), .init(status: "M", path: kotlinFile)])
        expect(screens(mixed.decision) == screens(kotlin) && mixed.unplaced.count == 1 && full(decide(gradle)) != nil,
               "for a branch, a build file beside a Kotlin change walks the Kotlin file's 2 screens and names the build file (\(mixed.unplaced.joined(separator: "; ")))")
        let onlyGradle = lenient([.init(status: "M", path: "app/build.gradle.kts")])
        expect(screens(onlyGradle.decision) == [] && onlyGradle.unplaced.count == 1, "a build file alone walks no screen and is named")
        expect(full(MapImpact.decideLenient(MapImpact.Input(baseline: noDeps, changes: [.init(status: "M", path: kotlinFile)], engine: "e1", profile: profile)).decision) != nil,
               "a baseline with no deps is still a full walk for a branch")
        var otherProfile = snap0; otherProfile.profile.depth = 5
        expect(full(decide(c1, baseline: otherProfile)) == "the walk's settings changed", "another profile walks everything")
        expect(full(decide(c1, patterns: [src])) == "a file under \(src) changed, where a quick walk missed a change before", "a workspace full-walk pattern is honoured")
        expect(MapImpact.kind(of: "app/src/main/res/drawable-xxhdpi/ic_star.9.png") == .resource("drawable/ic_star") && MapImpact.kind(of: "app/src/main/res/raw/faq.txt") == .resource("raw/faq")
               && MapImpact.kind(of: "app/src/main/assets/a.json") == .full("assets changed") && MapImpact.kind(of: "app/proguard-rules.pro") == .full("shrinker rules changed")
               && MapImpact.kind(of: ".github/workflows/ci.yml") == .ignored && MapImpact.kind(of: "app/src/androidTestDebug/x/A.kt") == .ignored,
               "paths: qualified drawables, raw files, assets, shrinker rules, CI and instrumented tests")
        expect(MapImpact.valueResources("    <string-array name=\"days\">") == ["array/days"] && MapImpact.valueResources("<item type=\"id\" name=\"row\"/>") == ["id/row"]
               && MapImpact.valueResources("<item>Monday</item>") == nil && MapImpact.valueResources("</resources>") == [] && MapImpact.valueResources("<plurals name=\"messages\">") == ["plurals/messages"],
               "values lines: arrays, typed items, unnamed items, plurals")

        // 3. Filing: the base (full), a quick walk of c1 seeded from it, the seed's round trip.
        var ws = Workspace(root: repo)
        ws.baseRef = "main"
        let now = Date()
        func build(_ sha: String) -> Build { Build(key: String(sha.prefix(12)), apk: walks.appendingPathComponent("x.apk"), source: .local, sha: sha, ref: nil, dirty: false, date: now) }
        let filed0 = sync { await History.filed(walk: full0, build: build(c0), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1") }
        expect(filed0?.snapshot.screens.count == 15 && filed0?.audit == nil, "the base walk is filed, with nothing to compare")
        let quick1 = walks.appendingPathComponent("quick-c1")
        writeWalk(quick1, models: models, carried: Set(ids.dropFirst(2)))
        let filedQ = sync { await History.filed(walk: quick1, build: build(c1), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", seed: filed0?.snapshot) }
        let quick = filedQ?.snapshot
        expect(quick?.screens.filter { $0.carriedFrom == nil }.count == 2 && quick?.screens.filter { $0.carriedFrom == c0 }.count == 13,
               "a quick walk of c1 is filed: 2 walked, 13 carried from the base")
        if let quick {
            let seedFolder = walks.appendingPathComponent("seed-roundtrip")
            let wrote = store.writeSeed(quick, to: seedFolder)
            let back = store.importWalk(seedFolder, commit: quick.commit, tree: quick.tree, profile: quick.profile, engine: quick.engine,
                                        walked: ISO8601DateFormatter().date(from: quick.walked) ?? now, seed: quick)
            var bare = quick
            for i in bare.screens.indices { bare.screens[i].lineage = "" }
            expect(wrote && back == bare, "the seed folder written from a snapshot reads back through importWalk to the same snapshot (lineages aside)")
            let only = (try? JSONSerialization.jsonObject(with: Data(contentsOf: seedFolder.appendingPathComponent("crawl.json")))) as? [String: Any]
            expect((only?["screens"] as? [[String: Any]])?.allSatisfy { (($0["captures"] as? [String: String])?["light"]).map { fm.fileExists(atPath: seedFolder.appendingPathComponent($0).path) } ?? false } == true,
                   "the seed folder has every capture, cloned from the store's blobs")

            // How the walk read its screens (crawl.json's screen_ids, clock, and the --freeze-network recording) goes into
            // the snapshot and back out into a seed, so the walk seeded from it makes the same ids at the same time with
            // the same server answers.
            let read = walks.appendingPathComponent("quick-c1-read")
            try? fm.removeItem(at: read)
            try? fm.copyItem(at: quick1, to: read)
            let har = Data(#"{"log": {"version": "1.2", "entries": [{"request": {"method": "GET", "url": "https://api.example/w"}}]}}"#.utf8)
            try? har.write(to: read.appendingPathComponent("network.har"))
            if var j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: read.appendingPathComponent("crawl.json")))) as? [String: Any] {
                j["screen_ids"] = 2; j["clock"] = "2026-11-25T21:04:00Z"; j["network"] = ["recording": "network.har", "entries": 1]
                j["dedup_variants"] = true; j["variant_aliases"] = ["Alias-0001": "Home-0001"]
                try? JSONSerialization.data(withJSONObject: j).write(to: read.appendingPathComponent("crawl.json"))
            }
            let withRead = store.importWalk(read, commit: quick.commit, tree: quick.tree, profile: quick.profile, engine: quick.engine,
                                            walked: ISO8601DateFormatter().date(from: quick.walked) ?? now, seed: filed0?.snapshot)
            expect(withRead?.screenIds == 2 && withRead?.clock == "2026-11-25T21:04:00Z" && withRead?.network.flatMap { store.blobURL($0) } != nil
                   && withRead?.dedupVariants == true && withRead?.variantAliases == ["Alias-0001": "Home-0001"],
                   "a walk's screen_ids, clock, dedup_variants, variant_aliases and recording are kept with its snapshot")
            if let withRead {
                let seed2 = walks.appendingPathComponent("seed-roundtrip-read")
                let wrote2 = store.writeSeed(withRead, to: seed2)
                let sj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: seed2.appendingPathComponent("crawl.json")))) as? [String: Any]
                expect(wrote2 && sj?["screen_ids"] as? Int == 2 && sj?["clock"] as? String == "2026-11-25T21:04:00Z"
                       && sj?["dedup_variants"] as? Bool == true && (sj?["variant_aliases"] as? [String: String]) == ["Alias-0001": "Home-0001"]
                       && (try? Data(contentsOf: seed2.appendingPathComponent("network.har"))) == har,
                       "a seed written from it has the same screen_ids, clock, dedup settings, and the recording as network.har")
                let back2 = store.importWalk(seed2, commit: withRead.commit, tree: withRead.tree, profile: withRead.profile, engine: withRead.engine,
                                             walked: ISO8601DateFormatter().date(from: withRead.walked) ?? now, seed: withRead)
                var bare2 = withRead
                for i in bare2.screens.indices { bare2.screens[i].lineage = "" }
                expect(back2 == bare2, "that seed reads back to the same snapshot")
                var shared = withRead
                shared.network = String(repeating: "0", count: 64)  // a teammate's map: the recording named, not in this store
                let seed3 = walks.appendingPathComponent("seed-shared")
                expect(store.writeSeed(shared, to: seed3) && !fm.fileExists(atPath: seed3.appendingPathComponent("network.har").path),
                       "a seed from a map whose recording is not in this store has none (the walk starts its own)")
            }
        }

        // 4. A planted miss: a full walk of c1 where screen 7, which the quick walk carried, differs.
        let full1 = walks.appendingPathComponent("full-c1")
        writeWalk(full1, models: models, recolor: [ids[6]])
        let filedF = sync { await History.filed(walk: full1, build: build(c1), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1") }
        let misses = filedF?.audit?.misses ?? []
        expect(misses.count == 1 && misses.first?.screen == ids[6] && misses.first?.why == "its capture changed" && misses.first?.files == [src + "TripsActivity.kt"],
               "the planted miss is reported: \(misses.map { "\($0.title): \($0.why), files \($0.files)" })")
        expect(store.snapshot(profile: profile.id, commit: c1)?.screens.allSatisfy { $0.carriedFrom == nil } == true, "the full walk replaced the quick walk's snapshot of c1")
        expect(store.ledger.patterns == [src] && store.ledger.misses.count == 1, "the missed file's directory became a full-walk pattern: \(store.ledger.patterns)")
        let note = Evidence.ImpactNote(full: true, reason: "every 10th walk of main is a full walk", walked: 15, total: 15, files: 1, base: nil, misses: 1, verify: nil)
        let lines = Evidence.impactLines(note)
        expect(lines.contains { $0.hasPrefix("1 screen changed that the last quick walk did not redo") }, "the row's detail says it: \(lines.joined(separator: " "))")
        let quickNote = Evidence.ImpactNote(full: false, reason: nil, walked: 3, total: 212, files: 12, base: "1a2b3c4")
        expect(Evidence.impactLines(quickNote).first == "Walked 3 of 212 screens (12 files changed); the other 209 were carried from the walk of 1a2b3c4.", "a quick walk's detail: \(Evidence.impactLines(quickNote).first ?? "")")
        expect(full(decide(c1, patterns: store.ledger.patterns))?.hasPrefix("a file under") == true, "with the pattern, the same change now walks everything")

        // 5. The plan of a walk of c2 on main: seeded from c1's (full) snapshot, the string's 2 screens named.
        let support = CrawlRun.Support(seed: true, recordDeps: true, maxActions: true, events: true)
        let work = walks.appendingPathComponent("plan-c2")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        // The ledger's pattern would make it full: the plan is checked with a clean ledger.
        store.updateLedger { $0.patterns = [] }
        let plan = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", support: support, forceFull: false, folder: work) }
        expect(plan.ids == [ids[2], ids[3]] && plan.total == 15 && plan.files == 1 && plan.seed.map { fm.fileExists(atPath: $0.appendingPathComponent("crawl.json").path) } == true
               && (try? String(contentsOf: plan.onlyFile ?? work, encoding: .utf8)) == ids[2] + "\n" + ids[3] + "\n",
               "a walk of c2 is planned seeded from c1, with the string's 2 screens in its only-file (\(plan.reason ?? "seeded"))")
        var diffing = support
        diffing.diffSeed = true
        let dplan = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", support: diffing, forceFull: false, folder: work) }
        expect(dplan.diffSeed && !plan.diffSeed && Set(dplan.reasons.keys) == Set(dplan.ids) && dplan.reasons.values.allSatisfy { !$0.isEmpty },
               "with a crawler that offers --diff-seed the walk is compared with its seed, and each screen's reason is kept (\(dplan.reasons[ids[2]]?.joined(separator: ", ") ?? "none"))")
        let newer = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e2", support: support, forceFull: false, folder: work) }
        expect(!newer.isFull && newer.ids == plan.ids && newer.engineChanged == "e1" && plan.engineChanged == nil,
               "after an engine update the walk is still seeded, and says its carried screens are to be verified (was \(newer.engineChanged ?? "none"))")
        let moved = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e2", support: support, forceFull: true,
                                              fullReason: "engine e2 reads 1 screen differently than e1 did", folder: work) }
        expect(moved.isFull && moved.reason == "engine e2 reads 1 screen differently than e1 did", "a full walk a verification asked for says why")
        let unsigned = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", support: support, forceFull: false, unsignedCounts: false, folder: work) }
        expect(unsigned.isFull && unsigned.seed == nil && unsigned.reason?.hasPrefix("not signed in") == true,
               "where only signed-in walks count, a walk that is not signed in starts from no map (\(unsigned.reason ?? "seeded"))")
        let none = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", support: .none, forceFull: false, folder: work) }
        expect(none.isFull && none.reason == nil && !none.recordDeps, "with the released engine's crawler the plan is a plain full walk, as before")
        let forced = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", support: support, forceFull: true, folder: work) }
        expect(forced.isFull && forced.reason == "asked to walk everything again" && forced.recordDeps, "\"Walk Everything Again\" is a full walk with deps")
        store.updateLedger { $0.mainWalks[profile.id] = 9 }
        let tenth = sync { await History.plan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", support: support, forceFull: false, folder: work) }
        expect(!tenth.isFull && tenth.diffControls == "all", "the tenth walk of main is seeded like the others, with every control of its screens tried: \(tenth.reason ?? "seeded")")

        // A walk compared with its seed says a carried screen is gone (apksim 0.63.0's `compare`): it is left out of
        // the snapshot, so the comparison with the seed shows it as removed. One the engine calls "unknown" stays.
        if let seedSnap = store.snapshot(profile: profile.id, commit: c1) {
            let goneWalk = walks.appendingPathComponent("gone-c2")
            writeWalk(goneWalk, models: models, carried: Set(ids).subtracting([ids[2], ids[3]]))
            let file = goneWalk.appendingPathComponent("crawl.json")
            if var json = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
                json["compare"] = [["id": NSNull(), "base": ids[7], "status": "gone", "why": "no screen of the new build reaches it"],
                                   ["id": NSNull(), "base": ids[8], "status": "unknown", "why": "it may still be there"],
                                   ["id": ids[2], "base": ids[2], "status": "same"]]
                try? JSONSerialization.data(withJSONObject: json).write(to: file)
            }
            let without = store.importWalk(goneWalk, commit: c2, tree: "t", profile: profile, engine: "e1", walked: Date(), seed: seedSnap)
            let removed = without.map { MapPairing.diff(head: MapPairing.pair(head: $0, base: seedSnap).0, base: seedSnap).screens.filter { $0.status == .removed }.compactMap(\.base) } ?? []
            expect(without?.screens.count == 14 && without?.screen(ids[7]) == nil && without?.screen(ids[8]) != nil && without?.edges.contains { $0.from == ids[7] } == false && removed == [ids[7]],
                   "a carried screen the engine calls gone is left out and shows as removed; one it calls unknown stays (removed: \(removed.joined(separator: ", ")))")
        } else { expect(false, "c1 has its snapshot for the gone-screen step") }

        // 6. "Verify carried screens": a quick walk of c2 (its 2 screens walked, 13 carried), then the verification's walk,
        // which reaches the 13 again (here written by hand, with one of them changed).
        store.updateLedger { $0 = MapImpact.Ledger() }
        let quick2 = walks.appendingPathComponent("quick-c2")
        writeWalk(quick2, models: models, carried: Set(ids).subtracting([ids[2], ids[3]]))
        let filed2 = sync { await History.filed(walk: quick2, build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1", seed: store.snapshot(profile: profile.id, commit: c1)) }
        let vwork = walks.appendingPathComponent("verify-work")
        try? fm.createDirectory(at: vwork, withIntermediateDirectories: true)
        let vplan = sync { await History.verifyPlan(build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, folder: vwork) }
        expect(filed2?.snapshot.screens.filter { $0.carriedFrom == c1 }.count == 13 && vplan?.ids.count == 13 && vplan?.ids.contains(ids[2]) == false,
               "verify: the 13 carried screens of c2's quick walk are named for the verification")
        if let vplan {
            let vwalk = walks.appendingPathComponent("verify-walk")
            writeWalk(vwalk, models: models, carried: [ids[2], ids[3]], recolor: [ids[9]])
            let r = sync { await History.verified(walk: vwalk, plan: vplan, build: build(c2), profile: profile, candidates: [ws], stateRoot: stateRoot, engine: "e1") }
            expect(r?.checked == 13 && r?.misses.map(\.screen) == [ids[9]] && r?.misses.first?.files == ["app/src/main/res/values/strings.xml"],
                   "verify: 13 carried screens compared, the changed one is a miss with c1..c2's file (\(r?.misses.map { "\($0.title): \($0.why), \($0.files)" } ?? []))")
            expect(store.ledger.misses.count == 1 && store.ledger.patterns.isEmpty, "verify: the miss is kept; it adds no pattern (a replay with no control tried is a lead, not proof)")
        }

        // 7. Live: a full walk with deps, then one seeded with one screen named.
        live(base: base, apk: apk, models: models, expect: expect)
        finish()
    }

    static func live(base: URL, apk: URL?, models: [Model], expect: (Bool, String) -> Void) {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("live", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let python = SnapshotRun.python() else { expect(false, "live: Python 3 is there"); return }
        var script: URL?
        var target: URL
        let engineSupport = ProcessInfo.processInfo.environment["GREENROOM_ENGINE"].map { _ in CrawlRun.support(python: python) } ?? .none
        if let apk, engineSupport.seed, engineSupport.recordDeps {
            try? Engine.shared.prepare()
            target = apk
            print("[greenroom] map-impact: live run on the engine at \(Engine.shared.root.path) (\(Engine.shared.version)), APK \(apk.lastPathComponent)")
        } else {
            let s = dir.appendingPathComponent("crawl.py")
            try? standin.write(to: s, atomically: true, encoding: .utf8)
            script = s
            target = dir.appendingPathComponent("app.apk")
            try? modelJSON(models).write(to: target)
            print("[greenroom] map-impact: live run on a stand-in crawler (no engine with --seed and --record-deps\(apk == nil ? ", no APK given" : ""))")
        }
        let support = CrawlRun.support(python: python, script: script)
        expect(support.seed && support.recordDeps, "live: the crawler's --help offers --seed, --only-file and --record-deps")


        func walk(_ name: String, seed: URL? = nil, only: URL? = nil, maxActions: Int? = nil, diffControls: String? = nil) -> (ok: Bool, seconds: Double, folder: URL, why: String) {
            let out = dir.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: out)
            var s = CrawlRun.Settings()
            s.depth = 3; s.seconds = 600; s.jobs = 1; s.appearances = ["light"]
            s.recordDeps = true; s.seed = seed; s.onlyFile = only; s.script = script; s.maxActions = maxActions; s.diffControls = diffControls
            if script == nil { s.engineOptions = ["--data-slots", SlotClone.freshName(prefix: "evg")] }
            let run = CrawlRun(python: python, apk: target, out: out, settings: s)
            var result: CrawlRun.Outcome?
            run.onFinish = { result = $0 }
            let started = Date()
            run.start()
            while result == nil, Date().timeIntervalSince(started) < 900 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let seconds = Date().timeIntervalSince(started)
            if case .finished? = result { return (true, seconds, out, "") }
            if case .failed(let why)? = result { return (false, seconds, out, why) }
            run.cancel(wait: true)
            return (false, seconds, out, "it did not finish")
        }
        let store = MapStore(root: dir.appendingPathComponent("state", isDirectory: true), repo: "live")
        let profile = MapProfile(depth: 3, seconds: 600)
        let first = walk("full")
        expect(first.ok, "live: the full walk with --record-deps finished in \(String(format: "%.1f", first.seconds)) s \(first.why)")
        guard first.ok, let a = store.importWalk(first.folder, commit: "live1", tree: "t", profile: profile, engine: "live", walked: Date()) else { return }
        // The engine records deps for the screens it explored; a screen it only reached has none (and is always walked again).
        let withDeps = a.screens.filter { $0.deps.map { !$0.sources.isEmpty } ?? false }.count
        expect(withDeps > 0 && a.startDeps.map { !$0.sources.isEmpty } == true && a.depsUnreliable == nil,
               "live: \(a.screens.count) screens, \(withDeps) with their deps (classes, sources, resources), and the app start's (\(a.startDeps?.sources.count ?? 0) source files)")
        let candidates = a.screens.filter { $0.settled && $0.flaky == nil && $0.deps != nil }
        guard let named = candidates.first(where: { $0.depth == 1 }) ?? candidates.first ?? a.screens.first else { return }
        let seed = dir.appendingPathComponent("seed", isDirectory: true), only = dir.appendingPathComponent("only.txt")
        guard store.writeSeed(a, to: seed), (try? Data((named.id + "\n").utf8).write(to: only)) != nil else { expect(false, "live: the seed was written"); return }
        let second = walk("seeded", seed: seed, only: only)
        expect(second.ok, "live: the seeded walk with one screen named (\(named.title.isEmpty ? named.id : named.title)) finished in \(String(format: "%.1f", second.seconds)) s against \(String(format: "%.1f", first.seconds)) s \(second.why)")
        guard second.ok, let b = store.importWalk(second.folder, commit: "live1", tree: "t", profile: profile, engine: "live", walked: ISO8601DateFormatter().date(from: a.walked) ?? Date(), seed: a) else { return }
        let walked = b.screens.filter { $0.carriedFrom == nil }.map(\.id)
        expect(walked == [named.id], "live: the second walk walked 1 screen and carried \(b.screens.count - walked.count)")
        // The classes that ran vary with what ran before (a lambda of a screen left behind): the impact rules read only
        // sources and resources, so classes are reported, not compared.
        var plain = b, ref = a
        for i in plain.screens.indices { plain.screens[i].carriedFrom = nil; plain.screens[i].deps?.classes = [] }
        for i in ref.screens.indices { ref.screens[i].deps?.classes = [] }
        plain.seconds = a.seconds
        var differ: [String] = []
        for s in plain.screens { if s != ref.screen(s.id) { differ.append(s.id) } }
        expect(plain == ref, "live: the seeded walk's result equals the full walk's apart from origin (screens, routes, captures, texts, sources, resources, unfinished)\(differ.isEmpty ? "" : "; differ: " + differ.joined(separator: ", "))")
        let classDiff = b.screens.filter { s in s.carriedFrom == nil && s.deps?.classes != a.screen(s.id)?.deps?.classes }
        if !classDiff.isEmpty {
            print("[greenroom] map-impact: note live: the classes recorded for \(classDiff.map { $0.id }.joined(separator: ", ")) differ between the two walks: " + classDiff.map { s in
                let x = Set(a.screen(s.id)?.deps?.classes ?? []), y = Set(s.deps?.classes ?? [])
                return "only in the full walk \(x.subtracting(y).sorted()), only in the seeded \(y.subtracting(x).sorted())"
            }.joined(separator: "; "))
        }
        expect(second.seconds < first.seconds, "live: the seeded walk took less time (\(String(format: "%.1f", second.seconds)) s against \(String(format: "%.1f", first.seconds)) s)")

        // The same seeded walk compared with its seed (`--diff-seed`, apksim 0.62.0): with every control tried it must
        // give the full walk's map; with only the seed's unknown controls tried, the same map, carried from the seed.
        if support.diffSeed, script == nil {
            for how in ["all", "changed"] {
                guard store.writeSeed(a, to: seed) else { expect(false, "live: the seed was written again"); break }
                let w = walk("diff-" + how, seed: seed, only: only, diffControls: how)
                expect(w.ok, "live: --diff-seed --diff-controls \(how) of the same screen finished in \(String(format: "%.1f", w.seconds)) s (plain seeded: \(String(format: "%.1f", second.seconds)) s) \(w.why)")
                guard w.ok, var d = store.importWalk(w.folder, commit: "live1", tree: "t", profile: profile, engine: "live", walked: ISO8601DateFormatter().date(from: a.walked) ?? Date(), seed: a) else { continue }
                for i in d.screens.indices { d.screens[i].carriedFrom = nil; d.screens[i].deps?.classes = [] }
                d.seconds = a.seconds
                var off: [String] = d.screens.filter { $0 != ref.screen($0.id) }.map(\.id)
                if d.edges != ref.edges { off.append("edges") }
                expect(d == ref, "live: its map equals the full walk's\(off.isEmpty ? "" : "; differ: " + off.joined(separator: ", "))")
                let json = (try? Data(contentsOf: w.folder.appendingPathComponent("crawl.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let pairs = (json?["compare"] as? [[String: Any]]) ?? []
                let changed = pairs.filter { ($0["status"] as? String) != "same" }
                expect(pairs.count == a.screens.count && changed.isEmpty,
                       "live: the engine's comparison with the seed pairs \(pairs.count) screens and calls none changed (the same build)\(changed.isEmpty ? "" : ": " + changed.map { "\($0["id"] as? String ?? "?") \($0["status"] as? String ?? "") \($0["why"] as? String ?? "")" }.joined(separator: "; "))")
            }
        }

        // The verification's walk: the carried screens named, no control tried.
        let carried = b.screens.filter { $0.carriedFrom != nil }.map(\.id)
        let only2 = dir.appendingPathComponent("only-verify.txt"), seed2 = dir.appendingPathComponent("seed-verify", isDirectory: true)
        guard store.writeSeed(b, to: seed2), (try? Data((carried.joined(separator: "\n") + "\n").utf8).write(to: only2)) != nil else { return }
        let third = walk("verify", seed: seed2, only: only2, maxActions: 0)
        let c = third.ok ? store.importWalk(third.folder, commit: "live1", tree: "t", profile: profile, engine: "live", walked: Date(), seed: b) : nil
        let reached = c.map { v in carried.filter { v.screen($0)?.carriedFrom == nil } } ?? []
        let same = c.map { v in reached.filter { id in v.screen(id)?.captures == b.screen(id)?.captures } } ?? []
        expect(third.ok && !reached.isEmpty, "live: the verification walk (--max-actions 0) re-walked \(reached.count) of the \(carried.count) carried screens in \(String(format: "%.1f", third.seconds)) s \(third.why)")
        // Reported, not judged: a screen whose content depends on what the full walk did before it (a job a button ran)
        // looks different when reached with no control tried. On a real app these are what verification calls misses.
        print("[greenroom] map-impact: note live: verification found \(same.count) of \(carried.count) carried screens with the same captures" + (same.count == carried.count ? "" : "; different or not reached the same way: " + carried.filter { !same.contains($0) }.map { id in
            let t = (b.screen(id)?.title).map { $0.isEmpty ? id : $0 } ?? id
            let w = c?.screen(id).map { v in Set(v.texts).symmetricDifference(b.screen(id)?.texts ?? []).sorted().joined(separator: " / ") } ?? "not reached"
            return "\(t) (\(w.isEmpty ? "pixels" : w))"
        }.joined(separator: "; ")))
    }

    /// The stand-in crawler: `scripts/crawl.py`'s arguments and crawl.json, for an "APK" that is a JSON model of screens.
    static let standin = #"""
#!/usr/bin/env python3
"""A stand-in for apksim's scripts/crawl.py (Greenroom's map-impact check): the same arguments and the same crawl.json,
for an "APK" that is a JSON model of an app's screens. Walking a screen takes STANDIN_SECONDS (0.25 s by default)."""
import argparse, json, os, shutil, struct, sys, time, zlib

ap = argparse.ArgumentParser(prog="crawl.py", description="Walks an app's screens (stand-in).")
ap.add_argument("apk")
ap.add_argument("--out", required=True)
ap.add_argument("--max-depth", type=int, default=3)
ap.add_argument("--max-seconds", type=int, default=180)
ap.add_argument("-j", type=int, default=1)
ap.add_argument("--matrix")
ap.add_argument("--no-captures", action="store_true")
ap.add_argument("--start")
ap.add_argument("--base")
ap.add_argument("--base-option")
ap.add_argument("--keep-data", action="store_true")
ap.add_argument("--seed", help="start from an earlier walk's folder")
ap.add_argument("--only-file", help="with --seed: the screen ids to explore again, one per line")
ap.add_argument("--record-deps", action="store_true", help="record what each screen depends on")
ap.add_argument("--max-actions", type=int, help="controls tried per screen")
ap.add_argument("--events", action="store_true", help="JSON lines beside the human lines")
argv = sys.argv[1:]
rest = argv[argv.index("--") + 1:] if "--" in argv else []     # engine options for the launches: not used here
a = ap.parse_args(argv[:argv.index("--")] if "--" in argv else argv)
cost = float(os.environ.get("STANDIN_SECONDS", "0.25"))
started = time.time()
model = json.load(open(a.apk))
combos = a.matrix.split("=", 1)[1].split(",") if a.matrix else []
if a.no_captures: combos = []
os.makedirs(os.path.join(a.out, "screens"), exist_ok=True)

def png(path, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * 4 for _ in range(4))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

def walk(m):
    time.sleep(cost)
    caps = {}
    for c in combos:
        rel = "screens/%s-%s.png" % (m["id"], c)
        png(os.path.join(a.out, rel), m["color"] if c == "light" else [255 - x for x in m["color"]])
        caps[c] = rel
    s = {"id": m["id"], "activity": m["activity"], "title": m["title"], "depth": m["depth"], "parent": m.get("parent"),
         "path": {"steps": m.get("steps", [])}, "captures": caps, "texts": m.get("texts", []), "settled": True, "origin": "walked"}
    if a.record_deps: s["deps"] = m["deps"]
    edges = [] if a.max_actions == 0 else [dict(e, **{"from": m["id"]}) for e in m.get("edges", [])]
    return s, edges

screens, edges = [], []
if a.seed:
    seed = json.load(open(os.path.join(a.seed, "crawl.json")))
    only = set(l.strip() for l in open(a.only_file)) if a.only_file else set()
    only.discard("")
    by = {m["id"]: m for m in model["screens"]}
    print("[new] depth 0: %d screen(s) to explore, %d known" % (len(only), len(seed["screens"])), flush=True)
    for s in seed["screens"]:
        if s["id"] in only and s["id"] in by:
            w, e = walk(by[s["id"]])
            if a.max_actions == 0: e = [x for x in seed["edges"] if x["from"] == s["id"]]
            screens.append(w); edges += e
        else:
            c = dict(s, origin="carried")
            caps = {}
            for combo, rel in s.get("captures", {}).items():
                to = "screens/carried-" + os.path.basename(rel)
                shutil.copyfile(os.path.join(a.seed, rel), os.path.join(a.out, to))
                caps[combo] = to
            c["captures"] = caps
            screens.append(c)
            edges += [x for x in seed["edges"] if x["from"] == s["id"]]
else:
    for d in range(0, 3):
        level = [m for m in model["screens"] if m["depth"] == d]
        if level: print("[new] depth %d: %d screen(s) to explore, %d known" % (d, len(level), len(screens)), flush=True)
        for m in level:
            w, e = walk(m)
            screens.append(w); edges += e
out = {"apk": os.path.basename(a.apk), "combos": combos, "screens": screens, "edges": edges, "findings": [], "incomplete": [],
       "seconds": {"total": round(time.time() - started, 3)}}
if a.record_deps: out["start_deps"] = model["start_deps"]
print("[new] %d screens, %d transitions" % (len(screens), len(edges)), flush=True)
json.dump(out, open(os.path.join(a.out, "crawl.json"), "w"), indent=1)
"""#
}
