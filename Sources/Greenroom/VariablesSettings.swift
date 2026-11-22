import AppKit
import SwiftUI

/// Settings > Variables: the person's sign-ins and test values, in the Keychain (Variables).
struct VariablesSection: View {
    @State private var rows: [(name: String, secret: Bool, onePassword: Bool)] = []
    @State private var plain: [String: String] = [:]
    @State private var name = ""
    @State private var value = ""
    @State private var secret = true
    @State private var problem: String?
    /// 1Password rows: name → reference (shown: it is not the secret), and what a test of each said.
    @State private var references: [String: String] = [:]
    @State private var tested: [String: (ok: Bool, text: String)] = [:]
    @State private var testing: Set<String> = []

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
        DispatchQueue.global(qos: .userInitiated).async {
            let (env, _) = LoginEnvironment.resolve()
            let r = OnePassword.read(ref, env: env)
            DispatchQueue.main.async {
                testing.remove(name)
                switch r {
                case .success(let v): tested[name] = (true, v.isEmpty ? "Read, but the field is empty" : "Read from 1Password (\(v.count) characters)")
                case .failure(let f): tested[name] = (false, f.errorDescription ?? "Could not read it")
                }
            }
        }
    }

    var body: some View {
        Section("Variables") {
            ForEach(rows, id: \.name) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.name).font(.system(.body, design: .monospaced))
                        Spacer()
                        if let ref = references[row.name] {
                            Text(ref).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "key.horizontal.fill").foregroundStyle(.secondary).help("Read from 1Password when a script runs")
                                .accessibilityLabel("from 1Password")
                            Button(testing.contains(row.name) ? "Testing…" : "Test") { test(row.name) }
                                .disabled(testing.contains(row.name))
                                .help("Read it from 1Password now, to check the reference (the value is not shown)")
                        } else {
                            Text(row.secret ? "••••••••" : (plain[row.name] ?? "")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if row.secret { Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("secret") }
                        }
                        Button {
                            Variables.shared.remove(row.name); tested[row.name] = nil; refresh()
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(row.name)")
                    }
                    if let t = tested[row.name] {
                        Text(t.text).font(.caption).foregroundStyle(t.ok ? Color.secondary : Color.red)
                    }
                }
            }
            HStack {
                TextField("Name", text: $name, prompt: Text("LOGIN_EMAIL"))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 150)
                if secret && !OnePassword.isReference(value) { SecureField("Value", text: $value, prompt: Text("value or op://Vault/Item/field")) }
                else { TextField("Value", text: $value, prompt: Text("value or op://Vault/Item/field")) }
                Toggle("Secret", isOn: Binding(get: { secret || OnePassword.isReference(value) }, set: { secret = $0 })).toggleStyle(.checkbox)
                    .disabled(OnePassword.isReference(value))
                Button("Add") { add() }.disabled(name.isEmpty)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Text("Passed as environment variables to the scripts you run (Device > Run Script), to build recipes, and to scripts you let agents run; an agent never reads one. Kept in your login Keychain, not in a file. A secret value shows as •••• in script and build output. Adding one with a name already there replaces it.")
                .font(.caption).foregroundStyle(.secondary)
            Text("From 1Password: give a secret reference as the value (op://Private/My App/password; in 1Password, an item's field menu has Copy Secret Reference). Greenroom keeps only the reference and reads the value with the 1Password CLI each time a script starts, by hand, before a signed-in screen map walk or when an agent runs one you allowed; 1Password asks you to approve. Needs the CLI (brew install 1password-cli) with 1Password > Settings > Developer > Integrate with 1Password CLI turned on. Build recipes don't get these.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            try Variables.shared.set(.init(name: n, value: value, secret: secret))
            name = ""; value = ""; problem = nil
            refresh()
        } catch {
            problem = error.localizedDescription
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
