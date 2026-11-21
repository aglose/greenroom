import Foundation

/// What a `remote` run leaves when it is killed without cleanup (its limit passed and the app quit, a crash, a power
/// cut): a sandbox still running, and a temporary folder with the source in it. The recipe writes `remote-state`
/// beside its APK as soon as they exist and removes it when it has cleaned up. The next run of the recipe does this
/// sweep itself (in the script); so does the app at launch, but only for a workspace whose person said yes to the
/// remote recipe: `boat` is never run otherwise.
enum RemoteLeftovers {
    struct Record: Equatable { var root: String; var tmp: String; var sandbox: String }

    static func parse(_ text: String) -> Record {
        var r = Record(root: "", tmp: "", sandbox: "")
        for line in text.split(separator: "\n") {
            if line.hasPrefix("root=") { r.root = String(line.dropFirst(5)) }
            else if line.hasPrefix("tmp=") { r.tmp = String(line.dropFirst(4)) }
            else if line.hasPrefix("sandbox=") { r.sandbox = String(line.dropFirst(8)) }
        }
        return r
    }

    static func stateFiles(in store: SessionStore) -> [URL] {
        let work = store.root.appendingPathComponent("sessions/work", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("remote-state") }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Stops the sandboxes and removes the folders of runs that were killed. Gives what it did, one line each.
    static func sweep(workspaces: [Workspace], store: SessionStore) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var said: [String] = []
                let fm = FileManager.default
                for file in stateFiles(in: store) {
                    let rec = parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                    let same = { (a: String, b: String) in URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path }
                    guard let ws = workspaces.first(where: { same($0.root.path, rec.root) }), ws.remote.consent == true else { continue }   // no yes, no boat
                    if !rec.tmp.isEmpty, URL(fileURLWithPath: rec.tmp).lastPathComponent.hasPrefix("greenroom-remote.") {
                        try? fm.removeItem(atPath: rec.tmp)
                        said.append("removed the temporary folder of an earlier remote run")
                    }
                    guard !rec.sandbox.isEmpty else { try? fm.removeItem(at: file); continue }
                    let env = LoginEnvironment.resolve().env
                    guard let boat = GH.find("boat", in: env["PATH"] ?? "") else { continue }   // not installed: try again at the next launch
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: boat)
                    p.arguments = ["stop", rec.sandbox]
                    p.environment = env
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    p.standardInput = FileHandle.nullDevice
                    guard (try? p.run()) != nil else { continue }
                    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
                    p.waitUntilExit()
                    killer.cancel()
                    if p.terminationStatus == 0 {
                        try? fm.removeItem(at: file)
                        said.append("stopped sandbox \(rec.sandbox), which an earlier remote run left running")
                    } else {
                        try? "root=\(rec.root)\nsandbox=\(rec.sandbox)\n".write(to: file, atomically: true, encoding: .utf8)
                        said.append("could not stop sandbox \(rec.sandbox): stop it yourself (boat stop \(rec.sandbox))")
                    }
                }
                cont.resume(returning: said)
            }
        }
    }
}

extension SessionsController {
    /// At launch: clean up after a remote run that was killed (only for workspaces that allowed the recipe).
    func sweepRemoteLeftovers() {
        let spaces = workspaces, store = self.store
        guard !RemoteLeftovers.stateFiles(in: store).isEmpty else { return }
        Task { @MainActor in
            for line in await RemoteLeftovers.sweep(workspaces: spaces, store: store) { NSLog("Greenroom: remote recipe: \(line)") }
        }
    }

    /// The remote recipe made a sandbox from the template: kept in the workspace's settings, so the next build resumes it.
    func noteCreatedSandbox(_ id: String, workspaceRoot: String) {
        guard !id.isEmpty, let i = workspaces.firstIndex(where: { $0.root.path == workspaceRoot }), workspaces[i].remote.sandbox.isEmpty else { return }
        workspaces[i].remote.sandbox = id
        store.saveWorkspaces(workspaces)
        workbench?.toast.show("Remote sandbox \(id) saved in the settings: the next build reuses it")
    }
}
