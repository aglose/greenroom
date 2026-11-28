import AppKit

/// `GREENROOM_STATE=EMPTY_DIR Greenroom --background --agent-check --waiting-check DIR`: the stage with no device on it (docs/AGENT-FIRST-SPEC.md, "Onboarding"). On
/// first run it shows the Connect screen: the harnesses found (stand-ins here, never the person's own), one button
/// that connects the ticked, then the prompt and what it hears. After that, with nothing running, it waits for an
/// agent and offers no drop target; File > Run an APK… puts the APK screen on it and Escape gives it back. A picture
/// of each is written to DIR (connect.png, connected.png, task.png, debug.png, waiting.png, apk.png) to look at. One
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
            expect(WaitingStage.statusText(client: "claude-code", listening: true) == "Listening · last heard from Claude Code", "it names the last agent heard from")
            expect(WaitingStage.statusText(client: nil, listening: true, connected: ["Claude Code"]) == "Listening · Claude Code connected", "... or what is connected, before any has called")
            expect(!WaitingStage.prompt.lowercased().contains("drop"), "the words for the agent ask it to build and open the app")
            expect(ConnectFlow.samplePrompt.contains("apk \"sample\""), "the sample app's words tell the agent how to launch it")

            // First run: the Connect screen, against stand-ins.
            let base = dir.appendingPathComponent("standins")
            ConnectCheck.standIns(base)
            ClaudeConnect.repositoryOnlyOverride = false   // the Debug copy's own screen has its case further down
            ConnectModel.lookups = true
            let model = ConnectModel.shared
            func refreshed() async { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in model.refresh { c.resume() } } }
            await settle()
            expect(wb.connectShown && !wb.waitingShown && !wb.apkScreenShown, "on first run the stage shows the Connect screen")
            expect(!ConnectModel.firstRunDone, "... and first run is not over")
            await refreshed()
            expect(model.pending.map(\.id) == ["claude", "codex", "cursor"], "it finds the three harnesses and ticks each: \(model.rows.map { "\($0.id) \(String(describing: $0.link))" })")
            await settle()
            capture(dir.appendingPathComponent("connect.png"))
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in model.connectTicked { c.resume() } }
            expect(model.connectedNames == ["Claude Code", "Codex", "Cursor"] && model.pending.isEmpty, "the one button connects all three: \(model.rows.compactMap(\.message))")
            expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("home/.cursor/mcp.json").path), "... Cursor through the file in the check's own home")
            await settle()
            capture(dir.appendingPathComponent("connected.png"))
            wb.connectFlow.step = 2
            wb.connectFlow.kind = 1
            expect(wb.connectFlow.prompt == ConnectFlow.samplePrompt && ConnectFlow.heard(client: nil) == "Listening for an agent…", "the second screen has the words to paste, and listens")
            wb.agentActivity.connected("claude-code")
            wb.agentActivity.add("launch", "the sample app, on a Pixel 9", failed: false)
            expect(wb.connectFlow.client == "claude-code" && ConnectFlow.heard(client: wb.connectFlow.client) == "Claude Code is connected", "an agent's first word shows there")
            expect(wb.connectFlow.lines == ["launch: the sample app, on a Pixel 9"], "... and then what it does: \(wb.connectFlow.lines)")
            await settle()
            capture(dir.appendingPathComponent("task.png"))
            // The Debug copy's screen: what it is, and its entry for every project.
            ClaudeConnect.repositoryOnlyOverride = true
            wb.connectFlow.step = 1
            await refreshed()
            expect(model.debugEntry == .connected && model.pending.isEmpty, "the Debug copy lists no harness and sees its entry for every project")
            await settle()
            capture(dir.appendingPathComponent("debug.png"))
            ClaudeConnect.repositoryOnlyOverride = false
            await refreshed()
            ClaudeConnect.repositoryOnlyOverride = nil
            wb.window.makeFirstResponder(nil)
            wb.connectFlow.onDone?()
            await settle()
            expect(!wb.connectShown && ConnectModel.firstRunDone, "leaving it ends first run")

            expect(wb.waitingShown && !wb.apkScreenShown, "with nothing running the stage waits for an agent")
            expect(wb.waitingTexts.first == "Listening · last heard from Claude Code", "... and names the last agent heard from: \(wb.waitingTexts.first ?? "-")")
            capture(dir.appendingPathComponent("waiting.png"))
            wb.connectAgents(nil)
            await settle()
            expect(wb.connectShown && wb.connectFlow.step == 1 && !wb.waitingShown, "File > Connect Agents… shows the Connect screen again")
            wb.window.firstResponder?.cancelOperation(nil)
            await settle()
            expect(!wb.connectShown && wb.waitingShown, "Escape gives the stage back")

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
