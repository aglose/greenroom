import AppKit

/// `GREENROOM_STATE=EMPTY_DIR Greenroom --background --agent-check --waiting-check DIR`: the stage with no device on it (docs/AGENT-FIRST-SPEC.md, "Onboarding"). With
/// nothing running it waits for an agent and offers no drop target; File > Run an APK… puts the APK screen on it and
/// Escape gives it back. A picture of each is written to DIR (waiting.png, apk.png) to look at. One
/// `[greenroom] waiting: ok|FAIL ...` line per step, then `waiting check: PASS|FAIL`; exits 0 or 1. No engine is started.
/// It is refused without a state folder of its own: on the person's, the window would show their sessions.
enum WaitingCheck {
    static func run(workbench wb: Workbench, dir: URL, capture: @escaping (URL) -> Void) {
        Task { @MainActor in
            var failures = 0
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("[greenroom] waiting: \(ok ? "ok  " : "FAIL") \(what)"); fflush(stdout) }
            func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            expect(WaitingStage.statusText(client: nil, listening: false) == "The agent endpoint is not running", "no endpoint: the stage says so")
            expect(WaitingStage.statusText(client: nil, listening: true) == "Listening · no agent has called yet", "listening, and no agent yet")
            expect(WaitingStage.statusText(client: "claude-code", listening: true) == "Listening · last heard from claude-code", "it names the last agent heard from")
            expect(!WaitingStage.prompt.lowercased().contains("drop"), "the words for the agent ask it to build and open the app")

            await settle()
            expect(wb.waitingShown && !wb.apkScreenShown, "with nothing running the stage waits for an agent")
            expect(wb.waitingTexts.contains { $0.hasPrefix("Listening") }, "... and says it is listening: \(wb.waitingTexts.first ?? "-")")
            wb.agentActivity.connected("claude-code")
            expect(wb.waitingTexts.first == "Listening · last heard from claude-code", "an agent's first word shows on the stage")
            capture(dir.appendingPathComponent("waiting.png"))

            wb.runAPK(nil)
            await settle()
            expect(wb.apkScreenShown && !wb.waitingShown, "File > Run an APK… puts the APK screen on the stage")
            capture(dir.appendingPathComponent("apk.png"))
            wb.window.firstResponder?.cancelOperation(nil)
            await settle()
            expect(wb.waitingShown && !wb.apkScreenShown, "Escape gives the stage back")

            print("waiting check: " + (failures == 0 ? "PASS" : "FAIL"))
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
