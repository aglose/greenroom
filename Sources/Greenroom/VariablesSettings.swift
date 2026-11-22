import AppKit
import SwiftUI

/// Settings > Variables: the person's sign-ins and test values, in the Keychain (Variables). Each row says what
/// kind it is; Add Variable… and a row's Edit open `VariableEditor`.
struct VariablesSection: View {
    @State private var rows: [(name: String, secret: Bool, onePassword: Bool)] = []
    @State private var plain: [String: String] = [:]
    /// 1Password rows: name → reference (shown: it is not the secret), and what a test of each said.
    @State private var references: [String: String] = [:]
    @State private var tested: [String: (ok: Bool, text: String)] = [:]
    @State private var testing: Set<String> = []
    /// The sheet: nil closed, "" adding, a name editing that variable.
    @State private var editing: String?
    @State private var removing: String?

    private func refresh() {
        rows = Variables.shared.names()
        var p: [String: String] = [:], refs: [String: String] = [:]
        for r in rows where !r.secret || r.onePassword {   // a secret value is never read here
            guard let v = Variables.shared.value(of: r.name) else { continue }
            if r.onePassword { refs[r.name] = v } else { p[r.name] = v }
        }
        plain = p
        references = refs
    }

    /// Reads the reference from 1Password (it may ask to approve) and says whether that worked: never the value.
    private func test(_ name: String) {
        guard let ref = references[name] else { return }
        testing.insert(name)
        VariableEditor.test(ref) { ok, text in
            testing.remove(name)
            tested[name] = (ok, text)
        }
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("No variables yet. Add the sign-ins your scripts type, such as LOGIN_EMAIL and LOGIN_PASSWORD.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        VariableKind.of(secret: row.secret, onePassword: row.onePassword).badge
                        Text(row.name).font(.system(.body, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 12)
                        if let ref = references[row.name] {
                            Text(ref).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(ref)
                            Button(testing.contains(row.name) ? "Testing…" : "Test") { test(row.name) }
                                .controlSize(.small)
                                .disabled(testing.contains(row.name))
                                .help("Read it from 1Password now, to check the reference (the value is not shown)")
                        } else {
                            Text(row.secret ? "••••••••" : (plain[row.name] ?? "")).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(row.secret ? "" : (plain[row.name] ?? ""))
                        }
                        Button { editing = row.name } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Edit \(row.name)")
                            .accessibilityLabel("Edit \(row.name)")
                        Button { removing = row.name } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(row.name)")
                            .accessibilityLabel("Remove \(row.name)")
                    }
                    if let t = tested[row.name] {
                        Label(t.text, systemImage: t.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(t.ok ? Color.green : Color.red)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = row.name }
            }
            HStack {
                Button { editing = "" } label: { Label("Add Variable…", systemImage: "plus") }
                Spacer()
            }
        } header: {
            Text("Variables")
        } footer: {
            Text("Environment variables for the scripts you run (Device > Run Script), for build recipes, and for scripts you let agents run; an agent never reads one. Kept in your login Keychain. Secret and 1Password values show as •••• in all output; build recipes don't get 1Password ones.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            VariableEditor(editing: editing?.isEmpty == false ? editing : nil, existing: Set(rows.map(\.name))) {
                if let n = editing { tested[n] = nil }
                editing = nil
                refresh()
            }
        }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let n = removing { Variables.shared.remove(n); tested[n] = nil; refresh() }
                removing = nil
            }
        } message: {
            Text("It is deleted from your login Keychain. Scripts that use it will no longer get it.")
        }
    }
}

/// What a variable is: shown as typed, a secret, or read from 1Password.
enum VariableKind: String, CaseIterable, Identifiable {
    case plain = "Value", secret = "Secret", onePassword = "1Password"
    var id: String { rawValue }

    static func of(secret: Bool, onePassword: Bool) -> VariableKind { onePassword ? .onePassword : (secret ? .secret : .plain) }

    var symbol: String {
        switch self {
        case .plain: return "textformat"
        case .secret: return "lock.fill"
        case .onePassword: return "key.horizontal.fill"
        }
    }

    var badge: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .help(self == .plain ? "Shown as it is" : (self == .secret ? "Secret: shown as ••••" : "Read from 1Password when a script runs"))
            .accessibilityLabel(rawValue)
    }

    var hint: String {
        switch self {
        case .plain: return "Shown here and in script output as it is: for a server URL, a user name, a test account's email."
        case .secret: return "Shown as •••• here and in all script and build output. Kept in your login Keychain."
        case .onePassword: return "In 1Password, open the item, click the field's menu and choose Copy Secret Reference, then paste it here (the quotes it comes in are fine). Greenroom keeps only the reference and reads the value with the 1Password CLI each time a script starts; 1Password asks you to approve."
        }
    }
}

/// The sheet that adds a variable or edits one: name, kind, value, and for 1Password a test before saving.
struct VariableEditor: View {
    /// The variable being edited (its name can't change), or nil when adding.
    let editing: String?
    /// Names already there: adding one of them replaces it, which the sheet says.
    let existing: Set<String>
    let done: () -> Void

    @State private var name = ""
    @State private var kind: VariableKind = .secret
    @State private var value = ""
    @State private var reveal = false
    /// Editing a secret: its value is not read back, so empty means "keep it".
    @State private var keepsSecret = false
    @State private var problem: String?
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @FocusState private var focus: Field?
    private enum Field { case name, value }

    init(editing: String?, existing: Set<String>, done: @escaping () -> Void) {
        self.editing = editing
        self.existing = existing
        self.done = done
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameProblem: String? {
        guard editing == nil, !cleanName.isEmpty else { return nil }
        if !Variables.isValid(cleanName) { return "Letters, digits and _ only, not starting with a digit, and not one Greenroom sets (GREENROOM_…, PATH, HOME…)." }
        return nil
    }
    private var replaces: Bool { editing == nil && existing.contains(cleanName) }
    private var valueProblem: String? {
        guard kind == .onePassword, !value.isEmpty, !OnePassword.isReference(value) else { return nil }
        return "A 1Password reference starts with op:// (op://Personal/Item/field)."
    }
    private var canSave: Bool {
        guard !cleanName.isEmpty, nameProblem == nil, valueProblem == nil else { return false }
        if kind == .onePassword { return OnePassword.isReference(value) }
        return !value.isEmpty || keepsSecret || kind == .plain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "Add Variable" : "Edit \(editing!)").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $name, prompt: Text("LOGIN_PASSWORD"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .disabled(editing != nil)
                            .focused($focus, equals: .name)
                            .onChange(of: name) { _, new in
                                // Environment names: spaces and dashes become _, letters upper case.
                                let fixed = new.uppercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                                if fixed != new { name = fixed }
                            }
                        if let nameProblem {
                            Text(nameProblem).font(.caption).foregroundStyle(.red)
                        } else if replaces {
                            Text("\(cleanName) already exists: saving replaces it.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                GridRow {
                    Text("Kind")
                    Picker("Kind", selection: $kind) {
                        ForEach(VariableKind.allCases) { k in Label(k.rawValue, systemImage: k.symbol).tag(k) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, _ in test = nil; reveal = false }
                }
                GridRow {
                    Text(kind == .onePassword ? "Reference" : "Value")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            valueField
                                .focused($focus, equals: .value)
                                .onChange(of: value) { _, new in
                                    test = nil
                                    // A pasted reference means 1Password, whatever kind was picked.
                                    if kind != .onePassword, OnePassword.isReference(new) { kind = .onePassword }
                                }
                            if kind == .secret {
                                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                                    .help(reveal ? "Hide the value" : "Show the value")
                                    .accessibilityLabel(reveal ? "Hide the value" : "Show the value")
                            }
                        }
                        if let valueProblem {
                            Text(valueProblem).font(.caption).foregroundStyle(.red)
                        } else if kind == .onePassword, OnePassword.isReference(value), OnePassword.normalized(value) != value {
                            Text("Saved as \(OnePassword.normalized(value))").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(kind.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let test {
                Label(test.text, systemImage: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(test.ok ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if kind == .onePassword {
                    Button(testing ? "Testing…" : "Test") { runTest() }
                        .disabled(testing || !OnePassword.isReference(value))
                        .help("Read it from 1Password now (it may ask you to approve); the value is not shown")
                }
                Spacer()
                Button("Cancel", role: .cancel) { done() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear(perform: load)
    }

    @ViewBuilder private var valueField: some View {
        switch kind {
        case .onePassword:
            TextField("Reference", text: $value, prompt: Text("op://Personal/My App/password"))
                .labelsHidden().font(.system(.body, design: .monospaced))
        case .secret where !reveal:
            SecureField("Value", text: $value, prompt: Text(keepsSecret ? "unchanged: type to replace" : "the value"))
                .labelsHidden()
        default:
            TextField("Value", text: $value, prompt: Text(keepsSecret ? "unchanged: type to replace" : "the value"))
                .labelsHidden()
        }
    }

    private func load() {
        guard let n = editing else { focus = .name; return }
        name = n
        let row = Variables.shared.names().first { $0.name == n }
        kind = VariableKind.of(secret: row?.secret ?? true, onePassword: row?.onePassword ?? false)
        if kind == .secret { keepsSecret = true }   // never read back into the sheet
        else { value = Variables.shared.value(of: n) ?? "" }
        focus = .value
    }

    private func save() {
        var v = value
        if kind == .secret, v.isEmpty, keepsSecret, let n = editing {
            guard let old = Variables.shared.value(of: n) else { problem = "The current value could not be read: type it again."; return }
            v = old
        }
        do {
            try Variables.shared.set(.init(name: cleanName, value: kind == .onePassword ? OnePassword.normalized(v) : v, secret: kind != .plain))
            done()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func runTest() {
        testing = true
        Self.test(value) { ok, text in testing = false; test = (ok, text) }
    }

    /// Reads a reference from 1Password off the main thread and says whether that worked, never the value.
    static func test(_ reference: String, then: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (env, _) = LoginEnvironment.resolve()
            let r = OnePassword.read(reference, env: env)
            DispatchQueue.main.async {
                switch r {
                case .success(let v): then(true, v.isEmpty ? "Read, but that field is empty in 1Password" : "Read from 1Password (\(v.count) characters)")
                case .failure(let f): then(false, f.errorDescription ?? "Could not read it")
                }
            }
        }
    }
}

/// Settings > Scripts: which scripts an agent may run, each as it is now.
struct ScriptsSection: View {
    @State private var scripts: [Scripts.Script] = []
    @State private var approvals: [String: Scripts.Approval] = [:]

    private func refresh() {
        scripts = Scripts.list(in: Scripts.folder)
        approvals = Dictionary(uniqueKeysWithValues: scripts.map { ($0.name, Scripts.approval($0)) })
    }

    var body: some View {
        Section("Scripts") {
            if scripts.isEmpty {
                Text("No scripts yet.").foregroundStyle(.secondary)
            }
            ForEach(scripts, id: \.name) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(get: { approvals[s.name] == .yes }, set: { on in Scripts.approve(s, on); refresh() })) {
                        Text(s.name).font(.system(.body, design: .monospaced))
                    }
                    if approvals[s.name] == .changed {
                        Text("Changed since you let agents run it: allow it again to let them run this version.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                Button("New Script…") { (NSApp.delegate as? AppDelegate)?.workbench.newScript(nil); refresh() }
                Button("Show Folder") { Scripts.prepareFolder(); NSWorkspace.shared.open(Scripts.folder) }
            }
            Text("You run any script on the chosen simulator from Device > Run Script or the command palette. An agent may run only those switched on here, and only as they were when you switched them on: editing one turns it off for agents. It gets the script's output with secret values as ••••, never the variables themselves.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }
}

extension AppDelegate {
    /// `Greenroom --variables-check DIR`: Settings > Variables and the add/edit sheet with sample variables (in memory,
    /// as every check keeps them), captured as PNGs in DIR for a look at the layout. One `[greenroom] variables:` line each.
    func variablesCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--variables-check"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for v in [Variables.Variable(name: "HOMESAFE_SERVER_URL", value: "https://debian-surveillance.tail4c441a.ts.net:8971", secret: false),
                  .init(name: "HOMESAFE_USERNAME", value: "admin", secret: false),
                  .init(name: "LOGIN_PASSWORD", value: "hunter2-check", secret: true),
                  .init(name: "PERCY_PASSWORD", value: "\"op://Personal/Frigate/password\"", secret: false)] { try? Variables.shared.set(v) }
        func shot(_ window: NSWindow, _ name: String) {
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                  let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() else {
                print("[greenroom] variables: FAIL no capture of \(name)"); return
            }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            print("[greenroom] variables: wrote \(name).png")
        }
        func editor(_ editing: String?) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: VariableEditor(editing: editing, existing: Set(Variables.shared.names().map(\.name))) {})
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            w.makeKeyAndOrderFront(nil)
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let w = SettingsWindow.shared.window { shot(w, "1-settings"); w.orderOut(nil) }
            let a = editor(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                shot(a, "2-add"); a.orderOut(nil)
                let b = editor("PERCY_PASSWORD")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    shot(b, "3-edit-1password"); b.orderOut(nil)
                    let c = editor("LOGIN_PASSWORD")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        shot(c, "4-edit-secret")
                        print("[greenroom] variables: done"); fflush(stdout)
                        exit(0)
                    }
                }
            }
        }
    }
}
