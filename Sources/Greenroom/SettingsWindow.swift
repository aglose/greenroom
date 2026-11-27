import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, variables, scripts, agents, recipes, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .variables: "Variables"
        case .scripts: "Scripts"
        case .agents: "Agents"
        case .recipes: "Build Recipes"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .variables: "key.horizontal"
        case .scripts: "terminal"
        case .agents: "sparkles"
        case .recipes: "hammer"
        case .privacy: "lock.shield"
        }
    }
}

/// Shared dark-glass styling helpers for Settings SwiftUI views.
enum SettingsTheme {
    static let stage = Color(nsColor: Design.stage)
    static let ink = Color(nsColor: Design.ink)
    static let mute = Color(nsColor: Design.mute)
    static let accent = Color(nsColor: Design.accent)
    static let onAccent = Color(nsColor: Design.onAccent)
    static let warning = Color(nsColor: Design.warning)
    static let record = Color(nsColor: Design.record)
    static let agent = Color(nsColor: Design.agent)
    static let cardFill = Color.white.opacity(0.055)
    static let wellFill = Color.black.opacity(0.32)
    static let stroke = Color.white.opacity(0.09)
}

struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SettingsTheme.stroke, lineWidth: 1)
        )
    }
}

struct SettingsCopyChip: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(SettingsTheme.ink)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied ✓" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(copied ? SettingsTheme.accent : SettingsTheme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
    }
}

/// Greenroom > Settings… (⌘,): dark-glass sidebar navigation over General, Variables, Scripts, Agents, Build Recipes & Privacy.
final class SettingsWindow: NSWindowController {
    static let shared = SettingsWindow()
    private var initialTab: SettingsTab = .general
    private var initialWorkspacePath: String?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Design.stage
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 660, height: 480)
        window.contentView = NSHostingView(rootView: SettingsView(initialTab: .general, initialWorkspacePath: nil))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: SettingsTab? = nil, workspacePath: String? = nil) {
        if let tab { initialTab = tab }
        if let workspacePath { initialWorkspacePath = workspacePath }
        window?.contentView = NSHostingView(rootView: SettingsView(initialTab: initialTab, initialWorkspacePath: initialWorkspacePath))
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab
    @State private var selectedWorkspacePath: String?

    @State private var automatic = Updates.shared.checksAutomatically
    @State private var crashes = Reports.shared.crashes
    @State private var usage = Reports.shared.usage
    @State private var waiting: [String] = []
    @State private var claudeSessions = ClaudeSessions.shared.enabled
    @State private var t3Sessions = T3Sessions.shared.enabled
    @State private var reopenLast = LastOpened.enabled
    @State private var autoArchive = UserDefaults.standard.object(forKey: SessionsController.autoArchiveKey) as? Bool ?? true
    @State private var sessionsWarm = max(1, min(6, UserDefaults.standard.object(forKey: "sessionsWarm") as? Int ?? 3))

    // Sidebar badges
    @State private var variableCount = 0
    @State private var hasModifiedScripts = false
    @State private var claudeConnected = false

    init(initialTab: SettingsTab = .general, initialWorkspacePath: String? = nil) {
        _selectedTab = State(initialValue: initialTab)
        _selectedWorkspacePath = State(initialValue: initialWorkspacePath)
    }

    private func refresh() {
        waiting = Reports.shared.waiting().map(\.1)
        crashes = Reports.shared.crashes
        usage = Reports.shared.usage
        automatic = Updates.shared.checksAutomatically
        reopenLast = LastOpened.enabled
        sessionsWarm = max(1, min(6, UserDefaults.standard.object(forKey: "sessionsWarm") as? Int ?? 3))
        variableCount = Variables.shared.names().count
        let scripts = Scripts.list(in: Scripts.folder)
        hasModifiedScripts = scripts.contains { Scripts.approval($0) == .changed }
        DispatchQueue.global(qos: .userInitiated).async {
            let connected = ClaudeConnect.status() == .connected
            DispatchQueue.main.async { claudeConnected = connected }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(SettingsTheme.stroke).frame(width: 1)
            ScrollView {
                tabContent
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.stage)
        }
        .background(SettingsTheme.stage)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(SettingsTheme.accent)
        .onAppear(perform: refresh)
        .frame(minWidth: 660, minHeight: 480)
    }

    var tabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch selectedTab {
            case .general: generalTab
            case .variables:
                VariablesSection(onCountChange: { variableCount = $0 })
            case .scripts:
                ScriptsSection(onChangedState: { hasModifiedScripts = $0 })
            case .agents: agentsTab
            case .recipes:
                WorkspaceRecipesSection(selectedPath: $selectedWorkspacePath)
            case .privacy: privacyTab
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 36)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 36)
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(isSelected ? SettingsTheme.accent : SettingsTheme.mute)
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? SettingsTheme.accent : SettingsTheme.ink)
                        Spacer()
                        sidebarBadge(for: tab)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? SettingsTheme.accent.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Divider().overlay(SettingsTheme.stroke)
            HStack {
                Text("Greenroom")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsTheme.mute)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(SettingsTheme.accent).frame(width: 6, height: 6)
                    Text("Local")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.28))
    }

    @ViewBuilder
    private func sidebarBadge(for tab: SettingsTab) -> some View {
        switch tab {
        case .variables where variableCount > 0:
            Text("\(variableCount)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(SettingsTheme.mute)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
        case .scripts where hasModifiedScripts:
            Circle().fill(SettingsTheme.warning).frame(width: 7, height: 7)
                .help("A script changed since you approved it for agents")
        case .agents where claudeConnected:
            Circle().fill(SettingsTheme.accent).frame(width: 7, height: 7)
                .help("Claude Code connected")
        default:
            EmptyView()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("General")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Text("App icon, simulator lifecycle, and updates.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.mute)
            }

            AppIconSection()

            SettingsCard {
                settingsToggleRow(
                    title: "Reopen what was open last",
                    subtitle: "At launch, Greenroom opens the session or APK you were using when it last quit. Off, it starts on the drop stage.",
                    isOn: $reopenLast
                )
                .onChange(of: reopenLast) { _, on in LastOpened.enabled = on }
            }

            SettingsCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Warm session simulators")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.ink)
                        Text("Keep up to \(sessionsWarm) session \(sessionsWarm == 1 ? "simulator" : "simulators") alive; least recently used quit automatically.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.mute)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(1...6, id: \.self) { count in
                            let active = sessionsWarm == count
                            Button("\(count)") {
                                sessionsWarm = count
                                UserDefaults.standard.set(count, forKey: "sessionsWarm")
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: active ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(active ? SettingsTheme.onAccent : SettingsTheme.mute)
                            .frame(width: 26, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(active ? SettingsTheme.accent : Color.clear)
                            )
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
                }
            }

            SettingsCard {
                if Updates.shared.available {
                    settingsToggleRow(
                        title: "Check for updates automatically",
                        subtitle: "Checks GitHub Releases with zero device or APK identifiers.",
                        isOn: $automatic
                    )
                    .onChange(of: automatic) { _, on in Updates.shared.checksAutomatically = on }

                    Divider().overlay(SettingsTheme.stroke)

                    HStack {
                        Text(lastChecked)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.mute)
                        Spacer()
                        Button("Check Now") { Updates.shared.checkForUpdates(nil) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsTheme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.09)))
                    }
                } else {
                    Text("Updates are off in this build (not a packaged app).")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                }
            }
        }
    }

    // MARK: - Agents

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Agents & MCP")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Text("Connect local coding agents to Greenroom simulators and surface active sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.mute)
            }

            SettingsCard {
                ClaudeConnectView(onStatusChange: { claudeConnected = ($0 == .connected) })
                Divider().overlay(SettingsTheme.stroke)
                settingsToggleRow(
                    title: "Show Claude Code sessions in sidebar",
                    subtitle: "Reads local Claude Code transcripts and read-only git status. Sent nowhere.",
                    isOn: $claudeSessions
                )
                .onChange(of: claudeSessions) { _, on in ClaudeSessions.shared.enabled = on }

                settingsToggleRow(
                    title: "Auto-archive session when its pull request merges",
                    subtitle: "Moves finished sessions to Archived in the + menu; worktree and data stay.",
                    isOn: $autoArchive
                )
                .disabled(!claudeSessions && !t3Sessions)
                .onChange(of: autoArchive) { _, on in UserDefaults.standard.set(on, forKey: SessionsController.autoArchiveKey) }
            }

            SettingsCard {
                settingsToggleRow(
                    title: "Show T3 Code threads",
                    subtitle: "Polls your local t3 CLI every 20 seconds while Greenroom is active to name worktree rows and suggest active threads.",
                    isOn: $t3Sessions
                )
                .onChange(of: t3Sessions) { _, on in T3Sessions.shared.enabled = on }
            }
        }
    }

    // MARK: - Privacy

    private var privacyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Privacy & Diagnostics")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Text("Local-first execution guarantee and optional crash telemetry.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.mute)
            }

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsTheme.accent.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SettingsTheme.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your APKs never leave this Mac")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                    Text("Every app runs natively on Apple Silicon. Greenroom never uploads APKs, screenshots, recordings, app data, or repository contents.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsTheme.accent.opacity(0.11)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SettingsTheme.accent.opacity(0.32), lineWidth: 1))

            SettingsCard {
                settingsToggleRow(title: "Send crash reports", subtitle: nil, isOn: $crashes)
                    .onChange(of: crashes) { _, on in Reports.shared.crashes = on; refresh() }

                settingsToggleRow(title: "Send usage statistics", subtitle: nil, isOn: $usage)
                    .onChange(of: usage) { _, on in Reports.shared.usage = on; refresh() }

                Text("Reports hold Greenroom's and macOS's versions, the day, and either a Greenroom crash address, an engine exit status, or feature counts. Never anything from your APKs.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.mute)

                Divider().overlay(SettingsTheme.stroke)

                DisclosureGroup {
                    if waiting.isEmpty {
                        Text("Nothing queued.")
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.mute)
                            .padding(.top, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView {
                                Text(waiting.joined(separator: "\n\n"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(SettingsTheme.mute)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 130)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))

                            HStack {
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(waiting.joined(separator: "\n\n"), forType: .string)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SettingsTheme.ink)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09)))

                                Button("Discard") {
                                    Reports.shared.discardWaiting()
                                    refresh()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SettingsTheme.record)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SettingsTheme.record.opacity(0.16)))
                            }
                        }
                        .padding(.top, 6)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Waiting to be sent")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsTheme.ink)
                        Text("\(waiting.count)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SettingsTheme.mute)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
                    }
                }

                if Reports.shared.endpoint == nil {
                    Text("This build has no address to send reports to: they stay on this Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.mute)
                }
            }
        }
    }

    private func settingsToggleRow(title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.mute)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private var lastChecked: String {
        guard let d = Updates.shared.lastChecked else { return "Never checked" }
        return "Last checked " + d.formatted(.relative(presentation: .named))
    }
}

/// Per-workspace CI & remote builder settings (replaces the legacy NSAlert in RecipesUI).
struct WorkspaceRecipesSection: View {
    @Binding var selectedPath: String?
    @State private var workspaces: [Workspace] = []
    @State private var moduleSpec = ""
    @State private var discoveredApps: [AndroidAppTarget] = []
    @State private var ciArtifact = ""
    @State private var ciAPK = ""
    @State private var ciWorkflow = ""
    @State private var remoteSandbox = ""
    @State private var remoteTemplate = ""
    @State private var remoteConsent: Bool? = nil
    @State private var savedBanner = false

    private var controller: SessionsController? { (NSApp.delegate as? AppDelegate)?.workbench.sessions }

    private var activeWorkspace: Workspace? {
        if let p = selectedPath, let w = workspaces.first(where: { $0.root.path == p }) { return w }
        return workspaces.first
    }

    private func reload() {
        workspaces = controller?.workspaces ?? []
        if selectedPath == nil || !workspaces.contains(where: { $0.root.path == selectedPath }) {
            selectedPath = workspaces.first?.root.path
        }
        loadFields()
    }

    private func loadFields() {
        guard let ws = activeWorkspace else { return }
        moduleSpec = ws.module ?? ""
        discoveredApps = AndroidProject.cachedApps(in: ws.root) ?? []
        let root = ws.root
        if AndroidProject.cachedApps(in: root) == nil {
            AndroidProject.probe(root) {
                if activeWorkspace?.root.path == root.path {
                    discoveredApps = AndroidProject.cachedApps(in: root) ?? []
                }
            }
        }
        ciArtifact = ws.ci.artifact
        ciAPK = ws.ci.apk
        ciWorkflow = ws.ci.workflow
        remoteSandbox = ws.remote.sandbox
        remoteTemplate = ws.remote.template
        remoteConsent = ws.remote.consent
    }

    private func save() {
        guard let c = controller, let ws = activeWorkspace,
              let i = c.workspaces.firstIndex(where: { $0.root.path == ws.root.path }) else { return }
        let trimmedMod = moduleSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        let newMod = trimmedMod.isEmpty ? nil : trimmedMod
        let moduleChanged = c.workspaces[i].module != newMod
        c.workspaces[i].ci.artifact = ciArtifact.trimmingCharacters(in: .whitespacesAndNewlines)
        c.workspaces[i].ci.apk = ciAPK.trimmingCharacters(in: .whitespacesAndNewlines)
        c.workspaces[i].ci.workflow = ciWorkflow.trimmingCharacters(in: .whitespacesAndNewlines)
        c.workspaces[i].remote.sandbox = remoteSandbox.trimmingCharacters(in: .whitespacesAndNewlines)
        c.workspaces[i].remote.template = remoteTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        c.store.saveWorkspaces(c.workspaces)
        if moduleChanged { c.setAppModule(newMod, for: ws.root, silent: true) }
        workspaces = c.workspaces
        savedBanner = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { savedBanner = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Build Recipes")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                    Text("Configure GitHub Actions CI and boat.dev remote builds per repository.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                }
                Spacer()
                if !workspaces.isEmpty {
                    Picker("", selection: Binding(
                        get: { activeWorkspace?.root.path ?? "" },
                        set: { selectedPath = $0; loadFields() }
                    )) {
                        ForEach(workspaces, id: \.root.path) { ws in
                            Text(ws.root.lastPathComponent).tag(ws.root.path)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }

            if activeWorkspace == nil {
                SettingsCard {
                    Text("No repositories added yet. Connect a Git repository from the sidebar or stage to configure CI and remote build recipes.")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                }
            } else {
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Android App & Module")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(SettingsTheme.ink)
                            Text(discoveredApps.count > 1
                                 ? "This repository has \(discoveredApps.count) Android apps. Choose which one to build and run."
                                 : "Leave blank to auto-detect, or set a Gradle module (e.g. :app or consumer/:app).")
                                .font(.system(size: 11.5))
                                .foregroundStyle(SettingsTheme.mute)
                        }
                        Spacer()
                        if discoveredApps.count > 1 {
                            Picker("", selection: $moduleSpec) {
                                ForEach(discoveredApps, id: \.id) { target in
                                    Text(target.displayName).tag(target.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }
                    }
                    field("Gradle module / composite target", text: $moduleSpec, placeholder: "Auto-detect (e.g. :app or consumer/:app)")
                }

                SettingsCard {
                    Text("GitHub Actions CI Recipe")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                    HStack(spacing: 12) {
                        field("Artifact name", text: $ciArtifact, placeholder: "e.g. app-debug-apk")
                        field("APK glob pattern", text: $ciAPK, placeholder: "*.apk")
                    }
                    field("Dispatch workflow (optional)", text: $ciWorkflow, placeholder: "ci.yml (needs workflow_dispatch)")
                }

                SettingsCard {
                    HStack {
                        Text("Remote Builder (boat.dev)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.ink)
                        Spacer()
                        Button("Copy Setup Script") { RemoteBuilder.copy() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(SettingsTheme.ink)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09)))
                    }
                    HStack(spacing: 12) {
                        field("Sandbox ID", text: $remoteSandbox, placeholder: "Resumed & stopped per build")
                        field("Template snapshot", text: $remoteTemplate, placeholder: "Snapshot id to create from")
                    }
                    Divider().overlay(SettingsTheme.stroke)
                    HStack {
                        let allowed = remoteConsent == true
                        Text("Source upload consent: ")
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsTheme.mute)
                        + Text(allowed ? "Allowed for this repo" : "Not granted")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(allowed ? SettingsTheme.accent : SettingsTheme.warning)
                        Spacer()
                        if allowed, let root = activeWorkspace?.root.path {
                            Button("Revoke") {
                                controller?.setRemoteConsent(nil, forRoot: root)
                                reload()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(SettingsTheme.record)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SettingsTheme.record.opacity(0.16)))
                        }
                    }
                }

                HStack {
                    if savedBanner {
                        Text("Saved ✓")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SettingsTheme.accent)
                    }
                    Spacer()
                    Button("Save Changes") { save() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsTheme.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.accent))
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsTheme.mute)
            TextField(label, text: text, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SettingsTheme.ink)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.wellFill))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
