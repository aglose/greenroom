import AppKit
import SwiftUI

/// Secure sign in: when the chosen device shows a sign-in screen (a password field), a Sign in button appears in the
/// bar. It opens a panel that either runs a sign-in script, or fills the fields on screen from the person's variables
/// (plain, secret or 1Password) and taps the button that submits them.
///
/// - Values are read only when Sign In is pressed, only for the variables chosen (so 1Password asks only for those),
///   and go straight to the device as typed text. Nothing shows them: not the panel, the toast or a log.
/// - What goes in which field is remembered per app, so the next time is one click. "Save as Script" writes the same
///   steps as a script (`gr tap-text`, `gr type "$VAR"`), which the Screen Map can sign in with and the person can
///   allow agents to run.
enum SecureSignIn {
    /// A field on the sign-in screen, by the text that names it (its hint, else description, else text).
    struct Field: Identifiable, Equatable {
        let label: String
        let password: Bool
        var id: String { label }
    }

    /// What the panel found on screen: the fields to fill and the buttons that may submit them, in screen order.
    struct Screen: Equatable {
        var fields: [Field] = []
        var buttons: [String] = []
        var isSignIn: Bool { fields.contains { $0.password } }
    }

    /// Which variable goes in which field, and which button to tap after. Kept per app.
    struct Plan: Codable, Equatable {
        var fields: [String: String] = [:]   // field label → variable name
        var submit: String?
    }

    static func fieldLabel(_ n: ScreenNode) -> String {
        for s in [n.hint, n.desc, n.password ? "" : n.text] where !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        return n.password ? "Password" : "Text field"
    }

    static func screen(_ nodes: [ScreenNode]) -> Screen {
        let ordered = nodes.sorted { ($0.top, $0.left) < ($1.top, $1.left) }
        var s = Screen()
        var seen = Set<String>()
        for n in ordered where n.field {
            var label = fieldLabel(n)
            if seen.contains(label) { label += " (\(seen.filter { $0.hasPrefix(label) }.count + 1))" }
            seen.insert(label)
            s.fields.append(Field(label: label, password: n.password))
        }
        s.buttons = ordered.filter { $0.click && !$0.field && !$0.label.isEmpty }.map(\.label)
        return s
    }

    // MARK: Guessing

    private static let submitWords = ["sign in", "log in", "login", "signin", "connect", "continue", "submit", "next", "enter", "go"]

    static func guessSubmit(_ buttons: [String]) -> String? {
        for w in submitWords {
            if let b = buttons.first(where: { $0.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix(w) }) { return b }
        }
        return nil
    }

    /// A variable for each field, by what the field is called: a password field takes a *PASS* variable, a user,
    /// email or account field a *USER*/*EMAIL*/*LOGIN* one, a server or URL field a *URL*/*SERVER*/*HOST* one. Where
    /// several fit, those sharing one prefix (HOMESAFE_...) win, so one app's set is picked together.
    static func guess(_ fields: [Field], names: [String]) -> [String: String] {
        func keys(_ f: Field) -> [String] {
            let l = f.label.lowercased()
            if f.password || l.contains("password") || l.contains("passcode") || l == "pin" { return ["PASS", "PIN"] }
            if l.contains("email") || l.contains("e-mail") { return ["EMAIL", "USER", "LOGIN"] }
            if l.contains("user") || l.contains("login") || l.contains("account") || l.contains("name") { return ["USER", "LOGIN", "EMAIL", "ACCOUNT"] }
            if l.contains("url") || l.contains("server") || l.contains("host") || l.contains("address") { return ["URL", "SERVER", "HOST"] }
            if l.contains("code") || l.contains("otp") || l.contains("token") { return ["CODE", "OTP", "TOKEN"] }
            return l.split { !$0.isLetter }.map { $0.uppercased() }.filter { $0.count >= 3 }
        }
        func prefix(_ name: String) -> String { name.split(separator: "_").first.map(String.init) ?? name }
        var candidates: [String: [String]] = [:]
        for f in fields {
            let k = keys(f)
            candidates[f.label] = names.filter { n in
                let up = n.uppercased()
                guard k.contains(where: { up.contains($0) }) else { return false }
                return f.password || !up.contains("PASS")   // a password never goes in a user name field
            }
        }
        // The prefix that fills the most fields.
        let prefixes = Set(candidates.values.flatMap { $0.map(prefix) })
        let best = prefixes.max { a, b in
            let ca = candidates.values.filter { $0.contains { prefix($0) == a } }.count
            let cb = candidates.values.filter { $0.contains { prefix($0) == b } }.count
            return ca != cb ? ca < cb : a > b
        }
        var out: [String: String] = [:]
        for f in fields {
            let c = candidates[f.label] ?? []
            if let pick = c.first(where: { prefix($0) == best }) ?? c.first { out[f.label] = pick }
        }
        return out
    }

    // MARK: Remembering

    private static func key(_ apk: URL) -> String { "secureSignIn." + apk.lastPathComponent }

    static func saved(for apk: URL) -> Plan? {
        UserDefaults.standard.data(forKey: key(apk)).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
    }

    static func remember(_ plan: Plan, for apk: URL) {
        if let d = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(d, forKey: key(apk)) }
    }

    /// The plan to start the panel with: what was saved for this app where the fields still exist, guesses for the rest.
    static func initialPlan(_ screen: Screen, apk: URL, names: [String]) -> Plan {
        let guessed = guess(screen.fields, names: names)
        var plan = Plan()
        let old = saved(for: apk)
        for f in screen.fields {
            if let v = old?.fields[f.label], names.contains(v) { plan.fields[f.label] = v } else if let g = guessed[f.label] { plan.fields[f.label] = g }
        }
        if let s = old?.submit, screen.buttons.contains(s) { plan.submit = s } else { plan.submit = guessSubmit(screen.buttons) }
        return plan
    }

    // MARK: Signing in

    /// Fills the planned fields on `sim` and taps the submit button. Blocks (1Password may ask to approve): never on
    /// the main thread. Answers what was done, or why it stopped; never a value.
    static func signIn(_ plan: Plan, on sim: Simulator) -> Result<String, Failure> {
        precondition(!Thread.isMainThread)
        let wanted = Set(plan.fields.values)
        let vars: [Variables.Variable]
        do {
            let (env, _) = LoginEnvironment.resolve()
            vars = try Variables.resolved(Variables.shared.all().filter { wanted.contains($0.name) }, env: env)
        } catch { return .failure(Failure(error.localizedDescription)) }
        let values = Dictionary(uniqueKeysWithValues: vars.map { ($0.name, $0.value) })
        if let missing = wanted.first(where: { values[$0] == nil }) { return .failure(Failure("\(missing) is not in Settings > Variables any more.")) }

        func send(_ c: String) -> String? {
            let a = sim.sendSync(c, timeout: 15)
            return a.hasPrefix("error") ? a.replacingOccurrences(of: "error: ", with: "") : nil
        }
        // Fresh positions: the screen may have moved since the panel opened (a keyboard, a scroll).
        func nodes() -> [ScreenNode] { ScreenNode.parse(sim.sendSync("nodes", timeout: 10)) }
        var filled = 0
        for field in screen(nodes()).fields {
            guard let name = plan.fields[field.label], let value = values[name] else { continue }
            guard let node = nodes().first(where: { $0.field && matches(fieldLabel($0), field.label) }) else {
                return .failure(Failure("The \(field.label) field is no longer on screen."))
            }
            let (x, y) = node.center
            // `settle` only waits: its "not settled" is no failure.
            func settle(_ ms: Int = 1500) { _ = sim.sendSync("settle \(ms) 100", timeout: 15) }
            if let why = send("tap \(x) \(y)") { return .failure(Failure("Filling \(field.label) failed: \(why)")) }
            settle()
            // Empty it: from the end, as many deletes as it holds (a field shows its hint when empty), checked again.
            for _ in 0..<3 {
                guard let now = nodes().first(where: { $0.field && matches(fieldLabel($0), field.label) }) else { break }
                let held = now.text == now.hint ? 0 : now.text.count
                if held == 0 { break }
                _ = send("key MOVE_END")
                _ = send("key DEL \(held + 2)")
                settle()
            }
            if let why = send("type64 " + Data(value.utf8).base64EncodedString()) { return .failure(Failure("Filling \(field.label) failed: \(why)")) }
            _ = sim.sendSync("settle 3000 150", timeout: 15)   // the typed text reaches the app before the next field
            filled += 1
        }
        guard filled > 0 else { return .failure(Failure("No field on screen was given a variable.")) }
        var done = "Filled \(filled) field\(filled == 1 ? "" : "s")"
        if let submit = plan.submit {
            guard let b = nodes().first(where: { $0.click && $0.label == submit }) else {
                return .failure(Failure(done + ", but \(submit) is not on screen to tap."))
            }
            if let why = send("tap \(b.center.0) \(b.center.1)") { return .failure(Failure(done + ", but tapping \(submit) failed: \(why)")) }
            done += " and tapped \(submit)"
        }
        return .success(done)
    }

    /// A field label as the panel numbered it ("Name (2)") matches the node's own.
    private static func matches(_ nodeLabel: String, _ label: String) -> Bool {
        nodeLabel == label || label.hasPrefix(nodeLabel + " (")
    }

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: As a script

    /// The plan as a Greenroom script: the same taps and typing with `gr`, values from the environment.
    static func script(_ plan: Plan, screen: Screen, app: String) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\"" }
        let used = screen.fields.compactMap { f in plan.fields[f.label].map { (f, $0) } }
        var s = """
            #!/bin/bash
            # Signs in to \(app). Written by Greenroom's Secure sign in: the values come from your variables
            # (Settings > Variables, which may read them from 1Password) and never appear in this file.
            set -euo pipefail

            """
        for name in Set(used.map(\.1)).sorted() { s += ": \"${\(name):?add \(name) in Greenroom > Settings > Variables}\"\n" }
        let first = used.first?.0.label ?? "Password"
        s += "\ngr wait \(q(first.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression))) 30\n"
        for (f, name) in used {
            let label = f.label.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
            s += "gr tap-text \(q(label))\ngr key MOVE_END\ngr key DEL 100\ngr type \"$\(name)\"\n"
        }
        if let submit = plan.submit { s += "gr tap-text \(q(submit))\n" }
        if let first = used.first?.0.label { s += "gr gone \(q(first.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression))) 40   # signed in once the sign-in screen has gone\n" }
        s += "echo \"signed in\"\n"
        return s
    }

    /// Writes the script into Greenroom's scripts folder under a free name, and answers its file.
    static func saveScript(_ text: String, app: String) throws -> URL {
        Scripts.prepareFolder()
        let slug = app.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0.hasSuffix("-") && $1 == "-" ? $0 : $0 + String($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = "sign-in-" + (slug.isEmpty ? "app" : String(slug.prefix(40)))
        var url = Scripts.folder.appendingPathComponent(base + ".sh")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = Scripts.folder.appendingPathComponent("\(base)-\(n).sh"); n += 1 }
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}

// MARK: The panel

/// The panel's state, shared between the SwiftUI view and the workbench that acts on it.
final class SecureSignInModel: ObservableObject {
    let app: String
    let screen: SecureSignIn.Screen
    let variables: [(name: String, kind: VariableKind)]
    let scripts: [Scripts.Script]
    @Published var plan: SecureSignIn.Plan
    @Published var busy: String?
    @Published var problem: String?
    var onSignIn: (SecureSignIn.Plan) -> Void = { _ in }
    var onRun: (Scripts.Script) -> Void = { _ in }
    var onSave: (SecureSignIn.Plan) -> Void = { _ in }
    var onVariables: () -> Void = {}

    init(app: String, screen: SecureSignIn.Screen, variables: [(name: String, kind: VariableKind)], scripts: [Scripts.Script], plan: SecureSignIn.Plan) {
        self.app = app; self.screen = screen; self.variables = variables; self.scripts = scripts; self.plan = plan
    }

    var canSignIn: Bool { busy == nil && screen.fields.contains { plan.fields[$0.label] != nil } }
}

struct SecureSignInView: View {
    @ObservedObject var model: SecureSignInModel

    private func kind(_ name: String) -> VariableKind? { model.variables.first { $0.name == name }?.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(.tint)
                Text("Secure sign in").font(.headline)
                Spacer()
                Text(model.app).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            if !model.scripts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RUN A SCRIPT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.scripts, id: \.url) { s in
                        HStack {
                            Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 18)
                            Text(s.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                            if s.fromWorktree { Text("session").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Run") { model.onRun(s) }.disabled(model.busy != nil)
                        }
                    }
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("FILL THIS SCREEN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if model.screen.fields.isEmpty {
                    Text("No text fields on this screen.").foregroundStyle(.secondary)
                } else if model.variables.isEmpty {
                    Text("Add your sign-in as variables first (a value, a secret, or a 1Password reference).").foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(model.screen.fields) { f in
                        GridRow {
                            Label(f.label, systemImage: f.password ? "lock" : "character.cursor.ibeam")
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: 170, alignment: .leading)
                            Picker(f.label, selection: Binding(get: { model.plan.fields[f.label] ?? "" },
                                                              set: { model.plan.fields[f.label] = $0.isEmpty ? nil : $0 })) {
                                Text("Leave as it is").tag("")
                                Divider()
                                ForEach(model.variables, id: \.name) { v in
                                    Label(v.name, systemImage: v.kind.symbol).tag(v.name)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 220)
                        }
                    }
                    if !model.screen.fields.isEmpty {
                        GridRow {
                            Text("Then tap").foregroundStyle(.secondary)
                            Picker("Then tap", selection: Binding(get: { model.plan.submit ?? "" }, set: { model.plan.submit = $0.isEmpty ? nil : $0 })) {
                                Text("Nothing").tag("")
                                Divider()
                                ForEach(model.screen.buttons, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(minWidth: 220)
                        }
                    }
                }
            }

            if let busy = model.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Values are typed into the app and never shown: not here, in a toast or a log, nor to an agent. 1Password asks you to approve the ones it holds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Variables…") { model.onVariables() }
                Button("Save as Script…") { model.onSave(model.plan) }
                    .disabled(!model.canSignIn)
                    .help("Write these steps as a script, to sign in from the Screen Map or let agents sign in")
                Spacer()
                Button("Sign In") { model.onSignIn(model.plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSignIn)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

// MARK: The workbench's part

extension Workbench {
    /// Every 1.5 s, asks the chosen device what is on screen, and shows the Sign in button while it has a password field.
    func startSignInWatch() {
        signInButton.target = self
        signInButton.action = #selector(showSecureSignIn(_:))
        signInButton.isHidden = true
        signInWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkSignInScreen() }
    }

    private func checkSignInScreen() {
        guard !signInAsking, window.isVisible, !window.isMiniaturized,
              let sim = selected, sim.isAlive, sim.state == .running, sim.framesShown > 0 else {
            if selected == nil || selected?.isAlive != true { offerSignIn(false) }
            return
        }
        signInAsking = true
        sim.send("nodes") { [weak self] raw in
            DispatchQueue.main.async {
                guard let self else { return }
                self.signInAsking = false
                guard sim === self.selected, !raw.hasPrefix("error") else { return }
                self.offerSignIn(ScreenNode.parse(raw).contains { $0.password })
            }
        }
    }

    private func offerSignIn(_ on: Bool) {
        guard signInButton.isHidden == on else { return }
        if on {
            signInButton.alphaValue = 0
            signInButton.isHidden = false
            Design.animate(Design.arrive, { self.signInButton.animator().alphaValue = 1 })
        } else if signInPopover?.isShown != true {
            signInButton.isHidden = true
        }
    }

    /// Device > Secure Sign In… and the bar's Sign in button: the panel for the chosen device's screen.
    @objc func showSecureSignIn(_ sender: Any?) {
        guard let sim = selected, sim.isAlive else { toast.show("No device is running", problem: true); return }
        if let p = signInPopover, p.isShown { p.close(); return }
        let worktree = worktree(of: sim)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let screen = SecureSignIn.screen(ScreenNode.parse(sim.sendSync("nodes", timeout: 10)))
            DispatchQueue.main.async { self?.presentSecureSignIn(sim: sim, screen: screen, worktree: worktree) }
        }
    }

    private func presentSecureSignIn(sim: Simulator, screen: SecureSignIn.Screen, worktree: URL?) {
        let rows = Variables.shared.names().map { (name: $0.name, kind: VariableKind.of(secret: $0.secret, onePassword: $0.onePassword)) }
        let app = sim.apk.deletingPathExtension().lastPathComponent
        let model = SecureSignInModel(app: app, screen: screen, variables: rows, scripts: Scripts.available(for: worktree),
                                      plan: SecureSignIn.initialPlan(screen, apk: sim.apk, names: rows.map(\.name)))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SecureSignInView(model: model))
        model.onVariables = { popover.close(); SettingsWindow.shared.show() }
        model.onRun = { [weak self] script in
            popover.close()
            ScriptWindow.start(script, on: sim, worktree: worktree, relativeTo: self?.window)
        }
        model.onSave = { [weak self] plan in
            SecureSignIn.remember(plan, for: sim.apk)
            do {
                let url = try SecureSignIn.saveScript(SecureSignIn.script(plan, screen: screen, app: app), app: app)
                popover.close()
                self?.toast.show("Saved \(url.lastPathComponent): pick it in the Screen Map, or allow it for agents in Settings")
            } catch { model.problem = "Could not write the script: \(error.localizedDescription)" }
        }
        model.onSignIn = { [weak self] plan in
            SecureSignIn.remember(plan, for: sim.apk)
            model.problem = nil
            model.busy = "Signing in…"
            DispatchQueue.global(qos: .userInitiated).async {
                let r = SecureSignIn.signIn(plan, on: sim)
                DispatchQueue.main.async {
                    model.busy = nil
                    switch r {
                    case .success(let done): popover.close(); self?.toast.show("Secure sign in: \(done)")
                    case .failure(let f): model.problem = f.message
                    }
                }
            }
        }
        let anchor: NSView = signInButton.isHidden ? (deviceButton ?? window.contentView!) : signInButton
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        signInPopover = popover
    }
}
