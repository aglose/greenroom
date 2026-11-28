import Foundation

/// `Greenroom --real-harness ID look|connect|disconnect`: what the Connect screen does for one harness (`claude`,
/// `codex`, `cursor`), run from a terminal against the real program and the real files on this Mac, and printed.
/// It is how a connector is tried on a real harness without clicking through the window.
///
/// This is not a check: it has no stand-ins. `connect` and `disconnect` change the harness's own configuration,
/// as the screen's buttons do (its MCP entry, the skill file, its hooks file), so nothing runs it but a person or an
/// agent they asked: no script in this repository does. `look` changes nothing.
///
/// In the Debug copy it connects the Debug copy, which the Connect screen never does (`ClaudeConnect.repositoryOnly`):
/// asking for a harness by name here is the asking. Disconnect it again afterwards.
enum RealHarness {
    static func run(id: String, action: String) -> Never {
        guard let h = Harnesses.connectable.first(where: { $0.id == id }), ["look", "connect", "disconnect"].contains(action) else {
            FileHandle.standardError.write(Data("usage: Greenroom --real-harness \(Harnesses.connectable.map(\.id).joined(separator: "|")) look|connect|disconnect\n".utf8))
            exit(2)
        }
        if Variant.isDebug { ClaudeConnect.repositoryOnlyOverride = false }
        ConnectModel.lookups = true
        func say(_ line: String) { print("[greenroom] real \(id): \(line)") }
        Thread.detachNewThread {
            let model = ConnectModel.shared
            let done = DispatchSemaphore(value: 0)
            var failed = false
            switch action {
            case "connect": DispatchQueue.main.async { model.connect(id) { done.signal() } }; done.wait()
            case "disconnect": DispatchQueue.main.async { model.disconnect(id) { done.signal() } }; done.wait()
            default:
                say("connecting would do this:")
                for line in h.how().split(separator: "\n", omittingEmptySubsequences: false) { say("  \(line)") }
            }
            if action != "look", let row = DispatchQueue.main.sync(execute: { model.rows.first { $0.id == id } }) {
                failed = row.failed
                say("\(action) \(row.failed ? "FAILED" : "ok"): \(row.message ?? "")")
            }
            // What is there now, read again from the harness itself.
            let link = h.status()
            say("link: \(link)")
            if let place = h.skill() { say("skill: \(place.shown): \(Skills.state(place))") } else { say("skill: not in a file of Greenroom's") }
            for place in Hooks.Place.all where place.id == id {
                say("hooks: \(place.shown): \(Hooks.state(place))" + (h.hooks() == place ? "" : " (not where this harness's hooks go now)"))
            }
            exit(failed ? 1 : 0)
        }
        dispatchMain()
    }
}
