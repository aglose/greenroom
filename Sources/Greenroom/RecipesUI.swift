import AppKit

// The sheets and menu items of the `ci` and `remote` recipes: the remote recipe's consent (it uploads source code),
// "Prepare remote builder" (steps and a script to copy: it runs nothing), and the per-workspace settings.

/// What the first use of the `remote` recipe asks.
enum RemoteConsent {
    /// The words the person answers. They say it in these words on purpose (docs/SESSIONS-PLAN.md, "Privacy").
    static func text(repo: String) -> (message: String, detail: String) {
        ("Upload \(repo)'s source code to your boat.dev account?",
         "The remote recipe uploads this repository's source code to your own boat.dev account, and builds it there. It sends the committed files, your uncommitted changes and the untracked files that .gitignore does not ignore, with the boat command-line tool and your own sign-in. Greenroom sends nothing itself, and the built APK comes back to this Mac: no APK is ever uploaded.\n\nThe sandbox is stopped when the build ends. Your answer is kept for this repository only; you can take it back from the Build menu.")
    }

    static func makeAlert(repo: String) -> NSAlert {
        let t = text(repo: repo)
        let alert = NSAlert()
        alert.messageText = t.message
        alert.informativeText = t.detail
        alert.addButton(withTitle: "Upload for \(repo)")
        alert.addButton(withTitle: "Don't Upload")
        return alert
    }
}

/// "Prepare remote builder": the steps and the script that make the template sandbox the `remote` recipe resumes.
/// It only shows and copies them: nothing here runs a command or talks to boat.dev.
enum RemoteBuilder {
    /// The steps, for the sheet.
    static let steps = [
        "Create a sandbox from boat.dev's base image.",
        "Install a JDK (17 or newer), git and unzip in it.",
        "Install the Android SDK command-line tools, accept the licences and install the platform and build tools your app needs.",
        "Save the sandbox as a snapshot: that is the template. Put its id (or a sandbox made from it) in the workspace's settings.",
    ]

    /// Written from boat's documentation, not run against the service: check each line against `boat --help`.
    static let script = """
    #!/bin/bash
    # Prepare a boat.dev sandbox for Greenroom's remote recipe. Run this yourself, in a terminal, with the boat CLI
    # signed in. Greenroom does not run it. Nothing here was run against the real service: correct the boat
    # commands to what `boat --help` says, and the SDK versions to the ones your app builds with.
    set -eu

    # 1. A sandbox; its id is the last word of what boat prints.
    ID="$(boat new | tail -n 1 | awk '{ print $NF }')"
    echo "sandbox: $ID"

    # 2. A JDK, git and unzip (adjust to the image's package manager).
    boat exec "$ID" --detach --cwd /home/user "sudo apt-get update && sudo apt-get install -y openjdk-17-jdk-headless git unzip curl > prepare.log 2>&1; echo done >> prepare.log"
    # ...wait for it (boat exec "$ID" --cwd /home/user "tail -n 3 prepare.log"), commands over 30 s need --detach.

    # 3. The Android SDK command-line tools, in /home/user/android-sdk (the recipe sets ANDROID_HOME to it).
    boat exec "$ID" --detach --cwd /home/user "mkdir -p android-sdk/cmdline-tools && cd android-sdk/cmdline-tools && curl -fsSLO https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip && unzip -q commandlinetools-linux-11076708_latest.zip && mv cmdline-tools latest && yes | latest/bin/sdkmanager --licenses > /home/user/sdk.log 2>&1 && latest/bin/sdkmanager 'platform-tools' 'platforms;android-35' 'build-tools;35.0.0' >> /home/user/sdk.log 2>&1; echo done >> /home/user/sdk.log"
    # ...wait for it the same way (tail -n 3 sdk.log).

    # 4. Save the snapshot (the command name is a guess: see boat --help) and keep its id.
    boat snapshot "$ID"
    boat stop "$ID"
    """

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Prepare remote builder"
        alert.informativeText = "The remote recipe resumes a boat.dev sandbox that already has a JDK and the Android SDK. Making one takes these steps, once. This only shows them: Greenroom runs nothing here and talks to no one. Copy the script, read it, and run it yourself in a terminal.\n\n"
            + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        text.string = script
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy Script")
        alert.addButton(withTitle: "Done")
        return alert
    }

    static func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(script, forType: .string)
    }
}

extension SessionsController {
    // MARK: Remote consent

    /// Asks once per repository whether the remote recipe may upload its source code, then runs `then` on a yes.
    /// A no is kept as a no (the recipe never runs) and asked again the next time the person chooses the recipe.
    func askRemoteConsent(for ws: Workspace, then: @escaping () -> Void) {
        guard let window = workbench?.window else { return }
        let repo = ws.root.lastPathComponent
        let alert = RemoteConsent.makeAlert(repo: repo)
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            let yes = r == .alertFirstButtonReturn
            self.setRemoteConsent(yes, forRoot: ws.root.path)
            if yes { then() }
        }
    }

    func setRemoteConsent(_ value: Bool?, forRoot root: String) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == root }) else { return }
        workspaces[i].remote.consent = value
        store.saveWorkspaces(workspaces)
    }

    func showRemoteBuilderSheet() {
        guard let window = workbench?.window else { return }
        let alert = RemoteBuilder.makeAlert()
        alert.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn { RemoteBuilder.copy() }
        }
    }

    // MARK: Settings

    /// The CI artifact, APK pattern and workflow, and the remote sandbox and template, of a session's workspace.
    func showBuildSettings(for session: Session) {
        guard let window = workbench?.window, let ws = workspace(of: session) else { return }
        let alert = NSAlert()
        alert.messageText = "Build settings for \(ws.root.lastPathComponent)"
        alert.informativeText = "Read by the ci and remote recipes. Empty means: for CI, the only artifact with an APK, matching *.apk, and no workflow is started; for remote, nothing."
        let labels = ["CI artifact", "CI APK pattern", "CI workflow", "Remote sandbox id", "Remote template"]
        let values = [ws.ci.artifact, ws.ci.apk, ws.ci.workflow, ws.remote.sandbox, ws.remote.template]
        let hints = ["name of the artifact", "*.apk", "ci.yml (needs workflow_dispatch)", "an existing sandbox, resumed and stopped each build", "a snapshot to create one from"]
        let fields = zip(values, hints).map { v, h -> NSTextField in
            let f = NSTextField(string: v); f.placeholderString = h; f.frame.size = NSSize(width: 300, height: 22); return f
        }
        let rows = zip(labels, fields).map { l, f -> NSStackView in
            let label = NSTextField(labelWithString: l); label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = NSStackView(views: [label, f]); row.spacing = 8; return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: CGFloat(rows.count) * 28)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self, let i = self.workspaces.firstIndex(where: { $0.root.path == ws.root.path }) else { return }
            let t = fields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            self.workspaces[i].ci.artifact = t[0]
            self.workspaces[i].ci.apk = t[1]
            self.workspaces[i].ci.workflow = t[2]
            self.workspaces[i].remote.sandbox = t[3]
            self.workspaces[i].remote.template = t[4]
            self.store.saveWorkspaces(self.workspaces)
        }
    }

    // MARK: Menu and palette

    /// What the "Build with" menu gets besides the recipes: settings, the builder's steps, taking the remote yes back.
    func recipeMenuItems(for s: Session, in ws: Workspace) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ClosureMenuItem("Build Settings…") { [weak self] in self?.showBuildSettings(for: s) },
                                   ClosureMenuItem("Prepare Remote Builder…") { [weak self] in self?.showRemoteBuilderSheet() }]
        if ws.remote.consent == true {
            items.append(ClosureMenuItem("Stop Allowing Remote Upload") { [weak self] in self?.setRemoteConsent(nil, forRoot: ws.root.path) })
        }
        return items
    }

    func recipePaletteItems() -> [PaletteItem] {
        [
            PaletteItem(id: "session.pull.add", title: "Add pull request…", group: "Sessions", symbol: "arrow.triangle.pull", keywords: "review pr github ci") { [weak self] in self?.pulls.askAndAdd() },
            PaletteItem(id: "session.remote.prepare", title: "Prepare remote builder…", group: "Sessions", symbol: "server.rack", keywords: "boat sandbox template android sdk") { [weak self] in self?.showRemoteBuilderSheet() },
            PaletteItem(id: "session.settings", title: "Build settings for this session…", group: "Sessions", symbol: "slider.horizontal.3", keywords: "ci artifact apk workflow remote sandbox template") { [weak self] in
                guard let self else { return }
                if let s = self.currentSession { self.showBuildSettings(for: s) } else { self.workbench?.toast.show("Add a repository first", problem: true) }
            },
        ]
    }
}
