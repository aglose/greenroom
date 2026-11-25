import Foundation

/// `Greenroom --sign-in-check DIR`: headless, no engine, nothing in the Keychain. The kept sign-in's store (a record
/// is there only while its data is; adopting another slot's data; forgetting deletes the data and nothing else); what
/// a walk's screens say about a sign-in (at the start, inside the app, none); and the recorder: taps by the text of
/// what was tapped or by position, typed text as variables that are secret unless typed into a field known not to
/// be a password's, backspace, keys, swipes, and a script that holds no typed value. One `ok|FAIL` line per step.
enum SignInCheck {
    static func run(dir: URL) -> Never {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { print("[greenroom] sign-in: \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
        let fm = FileManager.default
        let base = dir.appendingPathComponent("sign-in-check-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let root = base.appendingPathComponent("data", isDirectory: true)
        func slotFolder(_ pkg: String, _ slot: String, _ suffix: String = "") -> URL { root.appendingPathComponent(pkg).appendingPathComponent(slot + "-0" + suffix, isDirectory: true) }
        func make(_ pkg: String, _ slot: String, marker: String) {
            for s in ["", ".device"] { try? fm.createDirectory(at: slotFolder(pkg, slot, s), withIntermediateDirectories: true) }
            try? Data(marker.utf8).write(to: slotFolder(pkg, slot).appendingPathComponent("marker"))
        }
        func marker(_ pkg: String, _ slot: String) -> String? { (try? String(contentsOf: slotFolder(pkg, slot).appendingPathComponent("marker"), encoding: .utf8)) }

        // The slot's name and keys.
        let key = SignIns.key(workspace: URL(fileURLWithPath: "/tmp/Repo With Space/"))
        let slot = SignIns.slot(for: key)
        expect(slot.range(of: "^gsi[0-9a-f]{10}$", options: .regularExpression) != nil, "a kept slot's name is lower-case letters and digits (\(slot))")
        expect(SignIns.slot(for: key) == slot && SignIns.slot(for: SignIns.key(apk: URL(fileURLWithPath: "/x/app.apk"))) != slot, "one slot to a repository, another to an APK with none")

        // Data: there or not, adopted, and what adopting replaces.
        expect(!SignIns.hasData(slot, in: root), "no data, no sign-in")
        make("com.example.app", "gsn12345678", marker: "new")
        make("com.example.app", slot, marker: "old")
        make("com.other", slot, marker: "other")
        expect(SignIns.hasData(slot, in: root), "a slot some app has data in is a sign-in")
        expect(SignIns.adopt("gsn12345678", as: slot, in: root) && marker("com.example.app", slot) == "new", "adopting a slot's data replaces what was kept")
        expect(!fm.fileExists(atPath: slotFolder("com.example.app", "gsn12345678").path) && fm.fileExists(atPath: slotFolder("com.example.app", slot, ".device").path), "... and moves it, the device folder with it")
        expect(marker("com.other", slot) == "other", "... leaving another app's data in the slot alone")
        expect(!SignIns.adopt("gsn00000000", as: slot, in: root) && marker("com.example.app", slot) == "new", "adopting a slot with no data keeps what was there")

        // The record store (its own file; the data root is the engine's, so only the file is checked here).
        let file = base.appendingPathComponent("sign-ins.json")
        let store = SignIns(file: file)
        store.set(SignIns.Record(slot: slot, date: Date(timeIntervalSince1970: 1_800_000_000), script: "sign-in-app.sh"), key: key)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        expect(text.contains(slot) && text.contains("sign-in-app.sh") && !text.lowercased().contains("password"), "the store's file names the slot and the script, no credential")
        expect(((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int) == 0o600, "... and is readable by the person alone")
        expect(SignIns(file: file).record(key) == nil, "a record whose data is gone is no sign-in")

        // The wall.
        typealias S = (depth: Int, title: String, texts: [String])
        let signedOut: [S] = [(0, "Welcome", ["Welcome", "Email", "Password", "Sign in", "Forgot password?"]), (1, "Reset", ["Reset your password"])]
        expect(SignInWall.find(signedOut) == .atStart, "an app that opens on its sign-in: the wall is at the start")
        var app: [S] = [(0, "Home", ["Home", "Trips", "Settings"])]
        for i in 0..<12 { app.append((1, "Screen \(i)", ["Item \(i)", "Details"])) }
        expect(SignInWall.find(app) == .none, "an app with no sign-in: none")
        let gated = app + [(1, "Atlas is locked", ["Atlas is locked", "The server is out of reach"]), (1, "Packages", ["Sign in to your server to see your packages."])]
        expect(SignInWall.find(gated) == .inside(2), "screens that ask for a sign-in or say they are locked: counted")
        let settings = app + [(2, "Account", ["Change password", "Sign out"])]
        expect(SignInWall.find(settings) == .none, "a settings screen that mentions a password is not a wall")
        expect(SignInWall.atStart.note(kept: false)?.contains("Sign In Once") == true && SignInWall.atStart.note(kept: true)?.contains("no longer works") == true, "the note says what to do, and that a kept sign-in expired")
        expect(SignInWall.none.note(kept: false) == nil, "no wall, no note")

        // A sign-in script that ended well, and the screen it left the app on.
        func shown(password: Bool) -> [ScreenNode] {
            var t = ScreenNode(); t.text = "Server URL"; t.field = true
            var p = ScreenNode(); p.hint = "Password"; p.field = true; p.password = password
            var c = ScreenNode(); c.text = "Connect"; c.click = true
            return [t, p, c]
        }
        expect(MapSignIn.stillAtSignIn(shown(password: true)), "a script that leaves the app on a password field did not sign in")
        expect(!MapSignIn.stillAtSignIn(shown(password: false)), "... and one that leaves it on a screen with no password field did")
        expect(!MapSignIn.stillAtSignIn([]), "... and an empty answer is not read as a sign-in screen")

        // The recorder.
        func node(_ text: String, _ box: (Int, Int, Int, Int), field: Bool = false, password: Bool = false, click: Bool = true, hint: Bool = true) -> ScreenNode {
            var n = ScreenNode(); n.left = box.0; n.top = box.1; n.right = box.2; n.bottom = box.3; n.field = field; n.password = password; n.click = click
            if password && hint { n.hint = text } else { n.text = text }
            return n
        }
        let screen = [node("", (0, 0, 800, 1600), click: false), node("Email", (100, 300, 700, 380), field: true), node("Password", (100, 420, 700, 500), field: true, password: true),
                      node("Sign in", (100, 560, 700, 640)), node("hunter2-shown", (100, 700, 700, 780), field: true, password: true, hint: false)]
        let r = SignInRecorder(prefix: "SIGNIN_" + SignInRecorder.tag("Home Safe!"))
        func tap(_ x: Int, _ y: Int, late: Bool = false) {
            r.touch("down", x: x, y: y)
            if !late { r.nodes(screen, x: x, y: y) }
            r.touch("up", x: x, y: y)
            if late { r.nodes(screen, x: x, y: y) }   // the nodes' answer after the touch ended
        }
        tap(400, 340)
        r.text("me@exampel"); r.command("key DEL 1"); r.command("key DEL 1"); r.text("le.com")
        tap(400, 460, late: true)
        r.text("s3cret pass")
        r.command("key ENTER 1")
        tap(400, 600)
        r.touch("down", x: 400, y: 1200); r.touch("move", x: 400, y: 900); r.touch("move", x: 400, y: 600); r.touch("up", x: 400, y: 600)
        tap(790, 1590)            // nothing with a label there
        tap(400, 740)             // a password field's own text is never a label
        r.text("typed with no field known")
        r.finish()
        let script = r.script(app: "Home Safe", date: Date(timeIntervalSince1970: 1_800_000_000))
        let vars = r.variables
        expect(SignInRecorder.tag("Home Safe!") == "HOME_SAFE" && vars.map(\.name) == ["SIGNIN_HOME_SAFE_1", "SIGNIN_HOME_SAFE_2", "SIGNIN_HOME_SAFE_3"], "what was typed becomes variables named for the app (\(vars.map(\.name).joined(separator: ", ")))")
        expect(vars.first?.value == "me@example.com" && vars.first?.secret == false, "text typed into a field that is not a password's is kept as it is, backspaces applied")
        expect(vars.count > 1 && vars[1].value == "s3cret pass" && vars[1].secret, "text typed into a password field is a secret, even when the nodes came late")
        expect(vars.count > 2 && vars[2].secret, "... and so is text typed into a password field tapped by position")
        expect(!script.contains("me@example.com") && !script.contains("s3cret") && !script.contains("typed with no field") && !script.contains("hunter2"), "the script holds nothing that was typed or shown in a password field")
        let lines = script.split(separator: "\n").map(String.init)
        func index(_ l: String) -> Int { lines.firstIndex(of: l) ?? -1 }
        expect(index("gr wait 'Email' 30") >= 0 && index("gr tap-text 'Email'") == index("gr wait 'Email' 30") + 1 && index("gr type \"$SIGNIN_HOME_SAFE_1\"") == index("gr tap-text 'Email'") + 1, "a tap is found by its text, waited for first, and typing follows it")
        expect(index("gr tap-text 'Password'") > index("gr tap-text 'Email'") && index("gr key ENTER 1") > index("gr tap-text 'Password'") && index("gr tap-text 'Sign in'") > index("gr key ENTER 1"), "the steps are in the order they were made")
        expect(lines.contains("gr swipe 400 1200 400 600") && lines.contains("gr tap 790 1590") && lines.contains("gr tap 400 740"), "a drag is a swipe; a tap on nothing named, or on a password field, is by position")
        expect(lines.first == "#!/bin/bash" && lines.contains("set -euo pipefail") && lines.contains(": \"${SIGNIN_HOME_SAFE_2:?add SIGNIN_HOME_SAFE_2 in Greenroom > Settings > Variables}\""), "it is a Greenroom script that says which variables it needs")
        let quoted = SignInRecorder(prefix: "X")
        quoted.touch("down", x: 5, y: 5); quoted.nodes([node("Don't have an account?", (0, 0, 10, 10))], x: 5, y: 5); quoted.touch("up", x: 5, y: 5); quoted.finish()
        expect(quoted.script(app: "A").contains("gr tap-text 'Don'\\''t have an account?'"), "a label with a quote is quoted for the shell")
        expect(SignInRecorder(prefix: "X").isEmpty && !r.isEmpty, "a recorder nothing was done on is empty")

        try? fm.removeItem(at: base)
        print("[greenroom] sign-in check: \(failures == 0 ? "PASS" : "FAIL")")
        exit(failures == 0 ? 0 : 1)
    }
}
