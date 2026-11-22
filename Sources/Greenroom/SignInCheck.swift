import AppKit
import SwiftUI

extension AppDelegate {
    /// `Greenroom --signin-check DIR APK`: Secure sign in. Reading a sign-in screen and guessing its variables, the
    /// script it saves, and filling a real field on the training app (apksim://edittext) from a secret variable and
    /// from a 1Password reference (a stand-in `op`), twice, the second replacing the first. The panel is captured as
    /// DIR/signin-panel.png. One `[greenroom] signin:` line per expectation.
    func signInCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--signin-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1]), apk = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        func expect(_ ok: Bool, _ what: String, _ detail: String = "") {
            if !ok { failures += 1 }
            print("[greenroom] signin: \(ok ? "PASS" : "FAIL") \(what)\(ok || detail.isEmpty ? "" : " (\(detail))")"); fflush(stdout)
        }
        func end() {
            print("[greenroom] signin: \(failures == 0 ? "done" : "failed (\(failures))")"); fflush(stdout)
            UserDefaults.standard.removeObject(forKey: "secureSignIn." + apk.lastPathComponent)
            Engine.shared.stopAll()
            exit(failures == 0 ? 0 : 1)
        }

        // 1. A sign-in screen as the engine reports one (PercySafe's: a server, a user name, a password, Connect).
        let raw = #"[60,300,1020,400] field hint="Enter Server URL" ; [60,450,1020,550] field hint="Username" ; [60,600,1020,700] password-field hint="Password" text="••••" ; [60,800,1020,900] clickable text="Connect" ; [60,950,1020,1050] clickable text="These open without signing in""#
        let nodes = ScreenNode.parse(raw)
        let screen = SecureSignIn.screen(nodes)
        expect(screen.isSignIn, "a password field makes it a sign-in screen")
        expect(screen.fields.map(\.label) == ["Enter Server URL", "Username", "Password"], "its fields, by hint, in screen order", screen.fields.map(\.label).joined(separator: ", "))
        expect(!SecureSignIn.screen(ScreenNode.parse(#"[0,0,10,10] field hint="Search""#)).isSignIn, "a screen with no password field is not one")
        let names = ["HOMESAFE_SERVER_URL", "HOMESAFE_USERNAME", "HOMESAFE_PASSWORD", "PERCY_PASSWORD", "LOGIN_EMAIL"]
        let guess = SecureSignIn.guess(screen.fields, names: names)
        expect(guess == ["Enter Server URL": "HOMESAFE_SERVER_URL", "Username": "HOMESAFE_USERNAME", "Password": "HOMESAFE_PASSWORD"],
               "variables guessed per field, one app's set together", "\(guess)")
        expect(SecureSignIn.guessSubmit(screen.buttons) == "Connect", "Connect guessed as the button to tap")
        let plan = SecureSignIn.Plan(fields: guess, submit: "Connect")
        let script = SecureSignIn.script(plan, screen: screen, app: "PercySafe")
        expect(script.contains("gr tap-text \"Username\"") && script.contains("gr type \"$HOMESAFE_PASSWORD\"") && script.contains("gr tap-text \"Connect\""),
               "the saved script taps each field, types its variable and taps Connect", script)

        // The panel, for a look.
        let model = SecureSignInModel(app: "androidApp-debug", screen: screen,
                                      variables: [("HOMESAFE_SERVER_URL", .plain), ("HOMESAFE_USERNAME", .plain), ("HOMESAFE_PASSWORD", .onePassword), ("PERCY_PASSWORD", .onePassword)],
                                      scripts: [Scripts.Script(url: URL(fileURLWithPath: "/tmp/sign-in-percysafe.sh"), fromWorktree: false)], plan: plan)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: SecureSignInView(model: model))
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        // 2. A real fill: the training app's text field, from a secret, then from a 1Password reference.
        let fakeOp = dir.appendingPathComponent("op")
        try? FileManager.default.removeItem(at: fakeOp)
        FileManager.default.createFile(atPath: fakeOp.path, contents: Data("#!/bin/bash\nprintf 'from-1password'\n".utf8), attributes: [.posixPermissions: 0o700])
        OnePassword.cliOverride = fakeOp.path
        try? Variables.shared.set(.init(name: "GR_SIGNIN_SECRET", value: "first-secret", secret: true))
        try? Variables.shared.set(.init(name: "GR_SIGNIN_OP", value: "\"op://Private/Check/password\"", secret: false))
        guard let sim = workbench.open(apk, remember: false) else { expect(false, "the APK opens"); return end() }
        Task { @MainActor in
            let start = Date()
            while !(sim.state == .running && sim.framesShown > 0), Date().timeIntervalSince(start) < 240 { try? await Task.sleep(nanoseconds: 200_000_000) }
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
               let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(panel.windowNumber), 9)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("signin-panel.png"))
            }
            panel.orderOut(nil)
            guard sim.state == .running else { expect(false, "the training app starts"); return end() }
            let result: (String, String, String, String) = await Task.detached {
                _ = sim.sendSync("restart apksim://edittext")
                _ = sim.sendSync("settle 2000 100")
                let fields = SecureSignIn.screen(ScreenNode.parse(sim.sendSync("nodes"))).fields.map(\.label).joined(separator: ",")
                func fill(_ v: String) -> String {
                    switch SecureSignIn.signIn(.init(fields: ["Type here": v], submit: nil), on: sim) {
                    case .success(let s): return s
                    case .failure(let f): return "failed: " + f.message
                    }
                }
                let a = fill("GR_SIGNIN_SECRET")
                _ = sim.sendSync("settle 3000 150")
                let afterA = ScreenNode.parse(sim.sendSync("nodes")).first { $0.field }?.text ?? "none"
                let b = fill("GR_SIGNIN_OP")
                _ = sim.sendSync("settle 3000 150")
                let afterB = ScreenNode.parse(sim.sendSync("nodes")).first { $0.field }?.text ?? "none"
                return (fields, a + " / " + b, afterA, afterB)
            }.value
            expect(result.0.contains("Type here"), "the training app's field is found by its hint", result.0)
            expect(!result.1.contains("failed") && !result.1.contains("first-secret") && !result.1.contains("from-1password"),
                   "filling answers what it did, never a value", result.1)
            expect(result.2 == "first-secret", "a secret variable is typed into the field", result.2)
            expect(result.3 == "from-1password", "a 1Password one replaces what was there", result.3)
            Variables.shared.remove("GR_SIGNIN_SECRET")
            Variables.shared.remove("GR_SIGNIN_OP")
            OnePassword.cliOverride = nil
            end()
        }
    }
}
