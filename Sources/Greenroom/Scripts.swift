import AppKit
import CryptoKit
import Security

/// Scripts the person runs against a simulator by hand (Device > Run Script, the palette): to sign in, seed an
/// account, walk to a screen before a test. Any executable, in any language.
///
/// - Where: `<state>/scripts/` for every app, and `.greenroom/scripts/` of a session's worktree for that session's
///   simulator. Device > Run Script > New Script… writes a commented example.
/// - What a script gets: the person's Variables (the Keychain) as environment variables, and
///   `GREENROOM_CONTROL_PORT` / `GREENROOM_CONTROL_TOKEN` (the simulator's control channel), `GREENROOM_APK`,
///   `GREENROOM_DEVICE`, `GREENROOM_WORKTREE` (a session's), `GREENROOM_ENGINE_SCRIPTS` (the engine's drive.py,
///   ctl.py...). `gr` is on its PATH: `gr tap-text "Sign in"`, `gr type "$LOGIN_PASSWORD"`, `gr wait "Welcome"`, or any
///   control command (`gr key ENTER`).
/// - Output is shown in a window of its own, secret values masked; nothing is written to disk.
/// - An agent may run a script from `<state>/scripts/` only once the person has allowed it in Settings, and only
///   as it was when allowed: the approval is the file's SHA-256, in the Keychain. An agent never reads a variable.
enum Scripts {
    struct Script: Equatable {
        let url: URL
        var name: String { url.lastPathComponent }
        /// From a session's worktree rather than Greenroom's own folder.
        var fromWorktree: Bool
    }

    static var folder: URL { Engine.shared.state.appendingPathComponent("scripts", isDirectory: true) }
    static var binFolder: URL { Engine.shared.state.appendingPathComponent("bin", isDirectory: true) }

    static func worktreeFolder(_ worktree: URL) -> URL { worktree.appendingPathComponent(".greenroom/scripts", isDirectory: true) }

    /// The scripts in a folder: regular files, not hidden, not a README, by name.
    static func list(in dir: URL, fromWorktree: Bool = false) -> [Script] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) == true
                && !["md", "txt"].contains($0.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
         .map { Script(url: $0, fromWorktree: fromWorktree) }
    }

    /// What can run against `sim`: Greenroom's own scripts, then its session's.
    static func available(for worktree: URL?) -> [Script] {
        list(in: folder) + (worktree.map { list(in: worktreeFolder($0), fromWorktree: true) } ?? [])
    }

    static func prepareFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes an example script and answers its file (a free name: sign-in.sh, sign-in-2.sh...).
    static func newScript() throws -> URL {
        prepareFolder()
        var url = folder.appendingPathComponent("sign-in.sh")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("sign-in-\(n).sh"); n += 1 }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    static let template = """
        #!/bin/bash
        # A Greenroom script: run it on a simulator from Device > Run Script or the command palette (⌘K).
        #
        # Your variables (Settings > Variables, kept in the Keychain) are environment variables here, for example
        # LOGIN_EMAIL and LOGIN_PASSWORD. Secret ones show as •••• in the output.
        #
        # gr drives the simulator this runs on:
        #   gr tap-text "Sign in"      tap the first node whose text contains this
        #   gr type "$LOGIN_EMAIL"     type text into the focused field
        #   gr key ENTER               press a key (TAB, DEL, DPAD_DOWN...)
        #   gr wait "Welcome" 30       wait up to 30 s for text on screen (fails after)
        #   gr tap 400 900             tap at device pixels
        #   gr open "myapp://login"    open a deep link
        #   gr nodes                   the screen's nodes, one line
        #   gr ANY CONTROL COMMAND     anything the engine's control channel takes
        # Also set: GREENROOM_APK, GREENROOM_DEVICE, GREENROOM_WORKTREE (a session's), GREENROOM_ENGINE_SCRIPTS.
        set -euo pipefail

        : "${LOGIN_EMAIL:?add LOGIN_EMAIL in Greenroom > Settings > Variables}"
        : "${LOGIN_PASSWORD:?add LOGIN_PASSWORD in Greenroom > Settings > Variables}"

        gr wait "Sign in" 20
        gr tap-text "Email"
        gr type "$LOGIN_EMAIL"
        gr tap-text "Password"
        gr type "$LOGIN_PASSWORD"
        gr tap-text "Sign in"
        gr wait "Welcome" 30
        echo "signed in as $LOGIN_EMAIL"

        """

    // MARK: The gr helper

    /// Writes `<state>/bin/gr` (0700), the helper on every script's PATH. Bash only: no Python or nc needed.
    static func installHelper() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: binFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let gr = binFolder.appendingPathComponent("gr")
        if (try? String(contentsOf: gr, encoding: .utf8)) != helper {
            try? fm.removeItem(at: gr)
            guard fm.createFile(atPath: gr.path, contents: Data(helper.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        return gr
    }

    static let helper = #"""
        #!/bin/bash
        # gr: drives the simulator a Greenroom script runs on (Greenroom sets GREENROOM_CONTROL_PORT and _TOKEN).
        # Written by Greenroom: changes are replaced.
        set -u
        port=${GREENROOM_CONTROL_PORT:-}
        [ -n "$port" ] || { echo "gr: run this from a Greenroom script (no GREENROOM_CONTROL_PORT)" >&2; exit 2; }

        # One command, one answer line on stdout; status 1 when the engine answers "error...".
        send() {
          exec 3<>"/dev/tcp/127.0.0.1/$port" 2>/dev/null || { echo "gr: the simulator has gone" >&2; exit 2; }
          if [ -n "${GREENROOM_CONTROL_TOKEN:-}" ]; then
            printf 'auth %s\n' "$GREENROOM_CONTROL_TOKEN" >&3
            IFS= read -r ok <&3 || ok=
            [ "$ok" = ok ] || { exec 3>&-; echo "gr: the simulator refused the connection" >&2; exit 2; }
          fi
          printf '%s\n' "$1" >&3
          IFS= read -r answer <&3 || answer="error: no answer"
          exec 3>&-
          printf '%s\n' "$answer"
          case $answer in error*) return 1 ;; esac
          return 0
        }

        # The first node whose text contains $1: its centre as "X Y".
        find_node() {
          local all rest entry box l t r b
          all=$(send nodes) || return 1
          rest=$all
          while [ -n "$rest" ]; do
            entry=${rest%% ; *}
            if [ "$entry" = "$rest" ]; then rest=; else rest=${rest#* ; }; fi
            case $entry in
              *"$1"*)
                box=${entry#\[}; box=${box%%\]*}
                IFS=, read -r l t r b <<< "$box"
                echo "$(( (l + r) / 2 )) $(( (t + b) / 2 ))"
                return 0 ;;
            esac
          done
          return 1
        }

        cmd=${1:-}
        [ -n "$cmd" ] || { echo "usage: gr tap-text TEXT | type TEXT | wait TEXT [SECONDS] | gone TEXT [SECONDS] | open URL | COMMAND..." >&2; exit 2; }
        shift
        case $cmd in
          type)
            send "type64 $(printf '%s' "$*" | base64 | tr -d '\n')" >/dev/null ;;
          tap-text)
            xy=$(find_node "$*") || { echo "gr: no node with text \"$*\" on screen" >&2; exit 1; }
            send "tap $xy" >/dev/null ;;
          wait|gone)
            text=$1; secs=${2:-20}
            end=$(( $(date +%s) + secs ))
            while :; do
              all=$(send nodes) || exit 1
              case $all in *"$text"*) on=1 ;; *) on=0 ;; esac
              if [ "$cmd" = wait ] && [ $on = 1 ]; then exit 0; fi
              if [ "$cmd" = gone ] && [ $on = 0 ]; then exit 0; fi
              [ "$(date +%s)" -lt "$end" ] || { echo "gr: \"$text\" $([ "$cmd" = wait ] && echo "did not appear" || echo "is still on screen") within $secs s" >&2; exit 1; }
              sleep 0.3
            done ;;
          *)
            send "$cmd${*:+ $*}" ;;
        esac
        """#

    // MARK: Agent approvals

    /// The Keychain service holding approvals: account = script name, data = its SHA-256 when approved.
    private static var approvalService: String { (Bundle.main.bundleIdentifier ?? "Greenroom") + ".scripts" }
    private static var memoryApprovals: [String: String] = [:]
    private static var memory: Bool { CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-check") } }

    static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum Approval: Equatable { case no, yes, changed }

    /// Whether an agent may run the script: approved, and the file is byte for byte what was approved.
    static func approval(_ script: Script) -> Approval {
        guard !script.fromWorktree, let stored = approvedDigest(script.name) else { return .no }
        return digest(script.url) == stored ? .yes : .changed
    }

    static func approve(_ script: Script, _ on: Bool) {
        guard !script.fromWorktree else { return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: approvalService,
                                    kSecAttrAccount as String: script.name]
        if memory { memoryApprovals[script.name] = on ? digest(script.url) : nil; return }
        SecItemDelete(match as CFDictionary)
        guard on, let d = digest(script.url) else { return }
        var add = match
        add[kSecValueData as String] = Data(d.utf8)
        add[kSecAttrLabel as String] = "Greenroom script an agent may run"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func approvedDigest(_ name: String) -> String? {
        if memory { return memoryApprovals[name] }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: approvalService,
                                kSecAttrAccount as String: name, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// One run of a script against a simulator: its own process group, output as masked lines, a time limit.
final class ScriptRun {
    let script: Scripts.Script
    let simName: String
    /// Called on the main thread for each line, secrets masked.
    var onLine: ((String) -> Void)?
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var reaped = false
    private var lines: [String] = []
    private let env: [String: String]
    private let cwd: URL

    /// What the run came to: the exit code (nil: did not start, or stopped), and every line, masked.
    struct Outcome {
        var code: Int32?
        var timedOut: Bool
        var cancelled: Bool
        var failure: String?
        var output: [String]
    }

    /// Reads what the script needs of the simulator; main thread only.
    init?(script: Scripts.Script, sim: Simulator, worktree: URL?) {
        guard sim.isAlive, let port = sim.controlPort else { return nil }
        self.script = script
        simName = sim.name
        var e: [String: String] = [
            "GREENROOM_CONTROL_PORT": String(port),
            "GREENROOM_APK": sim.apk.path,
            "GREENROOM_DEVICE": DevHooks.value("--device", in: sim.options) ?? "phone",
            "GREENROOM_ENGINE_SCRIPTS": Engine.shared.root.appendingPathComponent("scripts").path,
        ]
        if let t = sim.controlToken { e["GREENROOM_CONTROL_TOKEN"] = t }
        if let worktree { e["GREENROOM_WORKTREE"] = worktree.path }
        env = e
        cwd = worktree ?? Scripts.folder
    }

    /// Runs it to the end, or for at most `timeout`. Blocks: never on the main thread.
    func runSync(timeout: TimeInterval) -> Outcome {
        precondition(!Thread.isMainThread)
        let helper: URL
        do { helper = try Scripts.installHelper() } catch { return Outcome(code: nil, timedOut: false, cancelled: false, failure: "Could not write the gr helper: \(error.localizedDescription)", output: []) }
        let (base, _) = LoginEnvironment.resolve()
        var full = base
        // One read of the Keychain, then 1Password for any reference (it may ask the person to approve).
        let vars: [Variables.Variable]
        do { vars = try Variables.resolved(Variables.shared.all(), env: base) } catch {
            return Outcome(code: nil, timedOut: false, cancelled: false, failure: error.localizedDescription, output: [])
        }
        let secrets = Variables.secrets(of: vars)
        for v in vars { full[v.name] = v.value }
        for (k, v) in env { full[k] = v }
        full["PATH"] = helper.deletingLastPathComponent().path + ":" + (full["PATH"] ?? "/usr/bin:/bin")

        Scripts.prepareFolder()   // the working folder when the simulator is no session's
        let path = script.url.path
        let fm = FileManager.default
        let (exe, args) = fm.isExecutableFile(atPath: path) ? (path, [String]()) : ("/bin/bash", [path])
        lock.lock(); let early = cancelled; lock.unlock()
        if early { return Outcome(code: nil, timedOut: false, cancelled: true, failure: nil, output: []) }
        let (spawned, why) = ProcessGroup.spawn(exe, args, env: full, cwd: cwd.path)
        guard let child = spawned else { return Outcome(code: nil, timedOut: false, cancelled: false, failure: "Could not start \(script.name): \(why)", output: []) }
        lock.lock(); pid = child.pid; let was = cancelled; lock.unlock()
        if was { killpg(child.pid, SIGTERM) }

        var splitter = LineSplitter()
        let emit: ([String]) -> Void = { [weak self] raw in
            guard let self, !raw.isEmpty else { return }
            let masked = raw.map { Variables.mask($0, secrets) }
            self.lock.lock(); self.lines.append(contentsOf: masked); if self.lines.count > 5000 { self.lines.removeFirst(self.lines.count - 5000) }; self.lock.unlock()
            DispatchQueue.main.async { masked.forEach { self.onLine?($0) } }
        }
        let r = ProcessGroup.drain(child, deadline: Date().addingTimeInterval(timeout), grace: 5,
                                   onData: { emit(splitter.feed($0)) },
                                   reaped: { [weak self] in self?.lock.lock(); self?.reaped = true; self?.lock.unlock() })
        if let last = splitter.finish() { emit([last]) }
        let status = r.status
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        lock.lock(); let stopped = cancelled; let out = lines; lock.unlock()
        return Outcome(code: stopped ? nil : code, timedOut: r.timedOut, cancelled: stopped, failure: nil, output: out)
    }

    /// Ends the script and everything it started (SIGTERM, then SIGKILL after five seconds unless it is gone).
    func cancel() {
        lock.lock(); cancelled = true; let p = pid; lock.unlock()
        guard p > 0 else { return }
        killpg(p, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let gone = self.reaped; self.lock.unlock()
            if !gone { killpg(p, SIGKILL) }
        }
    }
}

/// A script's output as it runs, in a window of its own, with Stop.
final class ScriptWindow: NSWindowController, NSWindowDelegate {
    private static var open: [ScriptWindow] = []
    /// Nil for a window showing a run that has already ended (a quick sign-in's output).
    private let run: ScriptRun?
    private let script: Scripts.Script
    private weak var sim: Simulator?
    private let text = NSTextView()
    private let status = NSTextField(labelWithString: "Running…")
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    /// "Don't Offer": takes back the quick sign-in this run has just saved.
    private let undoOffer = NSButton(title: "Don't Offer", target: nil, action: nil)
    private var savedOffer: SignInOffers.Offer?
    private var finished = false
    /// Called when a run saved a quick sign-in, or one was taken back (the stage looks again).
    static var onOffersChanged: (() -> Void)?

    /// Starts `script` on `sim` and shows its window. Manual runs may take up to ten minutes.
    @discardableResult
    static func start(_ script: Scripts.Script, on sim: Simulator, worktree: URL?, relativeTo parent: NSWindow?) -> ScriptWindow? {
        guard let run = ScriptRun(script: script, sim: sim, worktree: worktree) else {
            let a = NSAlert()
            a.messageText = "\(sim.name) is not ready for a script yet"
            a.informativeText = "Wait until the simulator shows the app, then run \(script.name) again."
            if let parent { a.beginSheetModal(for: parent) } else { a.runModal() }
            return nil
        }
        let w = ScriptWindow(script: script, simName: sim.name, run: run)
        w.sim = sim
        w.present(relativeTo: parent)
        w.begin()
        return w
    }

    /// A window with the output of a run that has ended, as a quick sign-in's failure shows it.
    static func showFinished(script: Scripts.Script, simName: String, outcome: ScriptRun.Outcome, relativeTo parent: NSWindow?) {
        let w = ScriptWindow(script: script, simName: simName, run: nil)
        w.present(relativeTo: parent)
        outcome.output.forEach(w.append)
        w.done(outcome)
    }

    private func present(relativeTo parent: NSWindow?) {
        Self.open.append(self)
        showWindow(nil)
        if let parent, let win = window {
            let f = parent.frame
            win.setFrameTopLeftPoint(NSPoint(x: f.maxX - win.frame.width - 24, y: f.maxY - 80))
        }
    }

    private init(script: Scripts.Script, simName: String, run: ScriptRun?) {
        self.run = run
        self.script = script
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        window.title = "\(script.name) on \(simName)"
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Script output")
        stop.target = self
        stop.action = #selector(stopOrClose(_:))
        stop.bezelStyle = .rounded
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        undoOffer.target = self
        undoOffer.action = #selector(takeBackOffer(_:))
        undoOffer.bezelStyle = .rounded
        undoOffer.isHidden = true
        undoOffer.toolTip = "Don't show a sign-in button for this script on this screen"
        let bar = NSStackView(views: [status, undoOffer, stop])
        bar.orientation = .horizontal
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 12)
        stack.spacing = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func begin() {
        guard let run else { return }
        run.onLine = { [weak self] line in self?.append(line) }
        let sim = self.sim
        let simID = sim.map(ObjectIdentifier.init)
        if let simID { QuickSignIn.scriptRunning.insert(simID) }
        DispatchQueue.global(qos: .userInitiated).async {
            // The screen it starts from: a sign-in it leaves becomes a quick sign-in (SignInOffers).
            let before = sim.flatMap(SignInOffers.capture)
            let o = run.runSync(timeout: 600)
            var after: SignInOffers.Print?
            if o.code == 0, o.failure == nil, before?.looksLikeSignIn == true, let sim, sim.isAlive { after = SignInOffers.capture(sim) }
            DispatchQueue.main.async { [weak self] in
                if let simID { QuickSignIn.scriptRunning.remove(simID) }
                self?.done(o)
                if let before, let after, !before.matches(after) { self?.offer(on: before) }
            }
        }
    }

    /// The run signed in from `screen` and left it: that screen offers the script from now on, once it is saved.
    private func offer(on screen: SignInOffers.Print) {
        guard SignInOffers.shared.add(script, on: screen), let saved = SignInOffers.shared.offers.last else { return }
        savedOffer = saved
        status.stringValue = "Finished · this sign-in screen now shows a button that runs \(script.name)"
        status.toolTip = status.stringValue
        undoOffer.isHidden = false
        Self.onOffersChanged?()
        NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: status.stringValue])
    }

    @objc private func takeBackOffer(_ sender: Any?) {
        guard let o = savedOffer else { return }
        SignInOffers.shared.remove(o)
        savedOffer = nil
        undoOffer.isHidden = true
        status.stringValue = "Finished"
        Self.onOffersChanged?()
    }

    private func append(_ line: String) {
        let attr = NSAttributedString(string: line + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor])
        text.textStorage?.append(attr)
        text.scrollToEndOfDocument(nil)
    }

    private func done(_ o: ScriptRun.Outcome) {
        finished = true
        stop.title = "Close"
        if let f = o.failure { status.stringValue = f }
        else if o.cancelled { status.stringValue = "Stopped" }
        else if o.timedOut { status.stringValue = "Stopped after 10 minutes" }
        else if o.code == 0 { status.stringValue = "Finished" }
        else { status.stringValue = "Failed (exit \(o.code ?? -1))" }
        status.textColor = (o.code == 0 && o.failure == nil) ? .secondaryLabelColor : .systemRed
        NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: status.stringValue])
    }

    @objc private func stopOrClose(_ sender: Any?) {
        if finished { window?.close() } else { run?.cancel(); status.stringValue = "Stopping…" }
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { run?.cancel() }
        Self.open.removeAll { $0 === self }
    }
}
