import AppKit
import SwiftUI

/// Settings > Variables: the person's sign-ins and test values, in the Keychain (Variables) or 1Password (`op://`).
struct VariablesSection: View {
    var onCountChange: ((Int) -> Void)? = nil

    @State private var rows: [(name: String, secret: Bool, onePassword: Bool)] = []
    @State private var plain: [String: String] = [:]
    @State private var name = ""
    @State private var value = ""
    @State private var secret = true
    @State private var useOnePassword = false
    @State private var showOPHelp = false
    @State private var problem: String?
    /// 1Password rows: name → reference (shown: it is not the secret), and what a test of each said.
    @State private var references: [String: String] = [:]
    @State private var tested: [String: (ok: Bool, text: String)] = [:]
    @State private var testing: Set<String> = []

    private func refresh() {
        rows = Variables.shared.names()
        onCountChange?(rows.count)
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
                case .success(let v): tested[name] = (true, v.isEmpty ? "Read, but the field is empty" : "Read from 1Password (\(v.count) characters — value never shown)")
                case .failure(let f): tested[name] = (false, f.errorDescription ?? "Could not read it")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Variables & Secrets")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Text("Passed as environment variables to scripts and builds. Masked as •••• in logs; agents never read them.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.mute)
            }

            // Stored variables list
            SettingsCard {
                if rows.isEmpty {
                    Text("No variables saved yet. Add a Keychain secret or 1Password reference below.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.name) { idx, row in
                            if idx > 0 { Divider().overlay(SettingsTheme.stroke).padding(.vertical, 8) }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 7) {
                                            Text(row.name)
                                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(SettingsTheme.ink)
                                            if references[row.name] != nil {
                                                badge("1Password", fill: SettingsTheme.agent.opacity(0.24), stroke: SettingsTheme.agent.opacity(0.55), fg: Color(red: 0.78, green: 0.74, blue: 1.0))
                                            } else if row.secret {
                                                badge("Keychain · Secret", fill: Color.white.opacity(0.08), stroke: SettingsTheme.stroke, fg: SettingsTheme.mute)
                                            } else {
                                                badge("Plain", fill: Color.white.opacity(0.06), stroke: SettingsTheme.stroke, fg: SettingsTheme.mute)
                                            }
                                        }
                                        if let ref = references[row.name] {
                                            Text(ref)
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundStyle(SettingsTheme.mute)
                                                .lineLimit(1).truncationMode(.middle)
                                        } else {
                                            Text(row.secret ? "••••••••••••" : (plain[row.name] ?? ""))
                                                .font(.system(size: 11.5, design: .monospaced))
                                                .foregroundStyle(SettingsTheme.mute)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                    if references[row.name] != nil {
                                        Button(testing.contains(row.name) ? "Testing…" : "Test") { test(row.name) }
                                            .buttonStyle(.plain)
                                            .disabled(testing.contains(row.name))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(SettingsTheme.ink)
                                            .padding(.horizontal, 9).padding(.vertical, 4)
                                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09)))
                                            .help("Read from 1Password now to verify the reference (the value is not shown)")
                                    }
                                    Button {
                                        Variables.shared.remove(row.name)
                                        tested[row.name] = nil
                                        refresh()
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(SettingsTheme.mute)
                                            .frame(width: 24, height: 24)
                                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(row.name)")
                                }
                                if let t = tested[row.name] {
                                    Text((t.ok ? "✓ " : "✕ ") + t.text)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(t.ok ? SettingsTheme.accent : SettingsTheme.record)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((t.ok ? SettingsTheme.accent : SettingsTheme.record).opacity(0.12)))
                                }
                            }
                        }
                    }
                }
            }

            // Add / replace variable card
            SettingsCard {
                HStack {
                    Text("Add or replace variable")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                    Spacer()
                    HStack(spacing: 2) {
                        sourceButton("Keychain", active: !useOnePassword) { useOnePassword = false }
                        sourceButton("1Password op://", active: useOnePassword) { useOnePassword = true }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.wellFill))
                }

                HStack(spacing: 8) {
                    TextField("Name", text: $name, prompt: Text("LOGIN_EMAIL"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SettingsTheme.ink)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(width: 155)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.wellFill))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))

                    Group {
                        if secret && !useOnePassword && !OnePassword.isReference(value) {
                            SecureField("Value", text: $value, prompt: Text("Secret value…"))
                        } else {
                            TextField("Value", text: $value, prompt: Text(useOnePassword ? "op://Vault/Item/field" : "Value or op://Vault/Item/field"))
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsTheme.ink)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.wellFill))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))

                    Button("Add") { add() }
                        .buttonStyle(.plain)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsTheme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.accent.opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1)))
                }

                HStack {
                    Toggle("Store as Keychain secret (masked in logs)", isOn: Binding(
                        get: { secret || useOnePassword || OnePassword.isReference(value) },
                        set: { secret = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.mute)
                    .disabled(useOnePassword || OnePassword.isReference(value))

                    Spacer()

                    Button(showOPHelp ? "Hide 1Password setup ▴" : "1Password setup ▾") {
                        withAnimation(.easeInOut(duration: 0.15)) { showOPHelp.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsTheme.mute)
                }

                if let problem {
                    Text(problem)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.record)
                }

                if showOPHelp {
                    Divider().overlay(SettingsTheme.stroke)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Copy a Secret Reference from 1Password (op://Vault/Item/field). Greenroom stores only the reference and reads the value on demand when a script runs. Enable 1Password › Settings › Developer › Integrate with 1Password CLI:")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.mute)
                        SettingsCopyChip(text: "brew install 1password-cli")
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func badge(_ text: String, fill: Color, stroke: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(stroke, lineWidth: 1))
    }

    private func sourceButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? SettingsTheme.ink : SettingsTheme.mute)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(active ? Color.white.opacity(0.14) : Color.clear))
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            try Variables.shared.set(.init(name: n, value: value, secret: secret || useOnePassword || OnePassword.isReference(value)))
            name = ""; value = ""; problem = nil
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Settings > Scripts: which scripts an agent may run, each as it is now.
struct ScriptsSection: View {
    var onChangedState: ((Bool) -> Void)? = nil

    @State private var scripts: [Scripts.Script] = []
    @State private var approvals: [String: Scripts.Approval] = [:]

    private func refresh() {
        scripts = Scripts.list(in: Scripts.folder)
        approvals = Dictionary(uniqueKeysWithValues: scripts.map { ($0.name, Scripts.approval($0)) })
        onChangedState?(approvals.values.contains(.changed))
    }

    private func openInEditor(_ script: Scripts.Script) {
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([script.url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([script.url])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scripts & Agent Approvals")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                    Text("Toggle which scripts agents may run. Editing a script automatically revokes approval.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Show Folder") { Scripts.prepareFolder(); NSWorkspace.shared.open(Scripts.folder) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SettingsTheme.ink)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.09)))

                    Button("+ New Script") {
                        (NSApp.delegate as? AppDelegate)?.workbench.newScript(nil)
                        refresh()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.onAccent)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.accent))
                }
            }

            SettingsCard {
                if scripts.isEmpty {
                    Text("No scripts yet. Create one to automate sign-ins or test flows on your simulators.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(scripts.enumerated()), id: \.element.name) { idx, s in
                            if idx > 0 { Divider().overlay(SettingsTheme.stroke).padding(.vertical, 8) }
                            let status = approvals[s.name] ?? .no
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(s.name)
                                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(SettingsTheme.ink)
                                        statusBadge(status)
                                    }
                                    Text(status == .changed
                                         ? "File changed since last approval; agents cannot run until re-approved."
                                         : (status == .yes ? "Approved for current file hash. Secret values stay masked." : "Run manually from Device › Run Script or ⌘K."))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(SettingsTheme.mute)
                                }
                                Spacer()
                                Button("Edit") { openInEditor(s) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(SettingsTheme.mute)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))

                                if status == .changed {
                                    Button("Re-approve") {
                                        Scripts.approve(s, true)
                                        refresh()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(SettingsTheme.warning)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SettingsTheme.warning.opacity(0.18)))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(SettingsTheme.warning.opacity(0.45), lineWidth: 1))
                                } else {
                                    Toggle("", isOn: Binding(
                                        get: { status == .yes },
                                        set: { on in Scripts.approve(s, on); refresh() }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func statusBadge(_ status: Scripts.Approval) -> some View {
        let (label, color): (String, Color) = switch status {
        case .yes: ("Agent allowed", SettingsTheme.accent)
        case .changed: ("Modified — re-approve", SettingsTheme.warning)
        case .no: ("Manual only", SettingsTheme.mute)
        }
        return Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(status == .no ? 0.12 : 0.16)))
    }
}
