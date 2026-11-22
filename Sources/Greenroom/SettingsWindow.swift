import AppKit
import SwiftUI

/// Greenroom > Settings… (⌘,): what the app may send, and the variables and scripts for sign-ins, in one place.
final class SettingsWindow: NSWindowController {
    static let shared = SettingsWindow()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.contentView = NSHostingView(rootView: SettingsView())   // fresh values each time
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @State private var automatic = Updates.shared.checksAutomatically
    @State private var crashes = Reports.shared.crashes
    @State private var usage = Reports.shared.usage
    @State private var waiting: [String] = []
    @State private var claudeSessions = ClaudeSessions.shared.enabled
    @State private var t3Sessions = T3Sessions.shared.enabled
    @State private var autoArchive = UserDefaults.standard.object(forKey: SessionsController.autoArchiveKey) as? Bool ?? true

    private func refresh() {
        waiting = Reports.shared.waiting().map(\.1)
        crashes = Reports.shared.crashes; usage = Reports.shared.usage; automatic = Updates.shared.checksAutomatically
    }

    var body: some View {
        Form {
            Section("Updates") {
                if Updates.shared.available {
                    Toggle("Check for updates automatically", isOn: $automatic)
                        .onChange(of: automatic) { _, on in Updates.shared.checksAutomatically = on }
                    HStack {
                        Text(lastChecked).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { Updates.shared.checkForUpdates(nil) }
                    }
                    Text("A check asks GitHub for the list of Greenroom versions. It sends no identifier and nothing about your Mac or your APKs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Updates are off in this build (not a packaged app).").foregroundStyle(.secondary)
                }
            }
            VariablesSection()
            ScriptsSection()
            Section("Claude Code") {
                Toggle("Show my Claude Code sessions", isOn: $claudeSessions)
                    .onChange(of: claudeSessions) { _, on in ClaudeSessions.shared.enabled = on }
                Text("Titles and status of your Claude Code sessions appear on the matching rows in Sessions. Read from Claude Code\u{2019}s own files on this Mac while this is on (small transcripts whole, long ones at their ends), checking whether each session\u{2019}s process still runs and running git, read-only, in the folders of sessions from repositories you have not added, whose names then show in the sidebar. Shown in this window and sent nowhere.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Archive a session when its pull request merges", isOn: $autoArchive)
                    .onChange(of: autoArchive) { _, on in UserDefaults.standard.set(on, forKey: SessionsController.autoArchiveKey) }
                    .disabled(!claudeSessions && !t3Sessions)
                Text("Takes it out of the sidebar once every pull request of its branch is closed and one merged, as Claude Code recorded it, and nothing runs in it. The worktree and its data stay; the + menu lists it under Archived.")
                    .font(.caption).foregroundStyle(.secondary)
                ClaudeConnectView()
            }
            Section("T3 Code") {
                Toggle("Show my T3 Code threads", isOn: $t3Sessions)
                    .onChange(of: t3Sessions) { _, on in T3Sessions.shared.enabled = on }
                Text("Threads of the repositories in Sessions name their worktree\u{2019}s row, with their status and pull requests, like Claude Code\u{2019}s sessions, and active ones are suggested. Asked of your own t3 command (t3 thread list and t3 thread show), which asks the T3 Code running on this Mac, every 20 seconds while Greenroom is in front. Nothing is sent anywhere else, and T3 Code\u{2019}s files are never opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Send crash reports", isOn: $crashes)
                    .onChange(of: crashes) { _, on in Reports.shared.crashes = on; refresh() }
                Toggle("Send usage statistics", isOn: $usage)
                    .onChange(of: usage) { _, on in Reports.shared.usage = on; refresh() }
                Text("Reports hold Greenroom's and macOS's versions, the day, and either a crash of Greenroom (its own code's addresses), an engine's exit status, or how often each Greenroom feature was used. Never anything from your APKs.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Waiting to be sent (\(waiting.count))") {
                    if waiting.isEmpty {
                        Text("Nothing.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(waiting.joined(separator: "\n\n")).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 140)
                        Button("Discard These") { Reports.shared.discardWaiting(); refresh() }
                    }
                }
                if Reports.shared.endpoint == nil {
                    Text("This build has no address to send reports to: they stay on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: refresh)
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
    }

    private var lastChecked: String {
        guard let d = Updates.shared.lastChecked else { return "Never checked" }
        return "Last checked " + d.formatted(.relative(presentation: .named))
    }
}
