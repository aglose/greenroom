import AppKit

/// A repository's own simulator launch (Workspace.skin, Workspace.launchOptions): a stored device skin and any further
/// apksim options, added to every simulator Greenroom starts for that repository (main's row, its sessions, its pull
/// requests, and an agent's launch). Set before the first launch (the sheet shown when a repository is added) or later
/// in Settings > Build Recipes and the repository's + menu.
enum LaunchSettings {
    /// One stored skin, as `apksim skin list --json` gives it.
    struct Skin: Decodable, Equatable {
        let name: String
        var title: String?
        var device: String?
        var kind: String?
        var origin: String?
        var label: String { title.map { "\($0) (\(name))" } ?? name }
    }

    /// Options Greenroom sets on every launch itself, with how many values each takes: dropped from a person's own,
    /// since the simulator would not show in Greenroom (or would hold another session's data) with them changed.
    static let reserved: [String: Int] = [
        "--headless": 0, "--window": 1, "--control": 1, "--control-token-file": 1, "--data-slots": 1, "--instrument": 1,
    ]

    // MARK: Moving shared data

    /// The engine's option for APKs with a 4 KB-aligned native library whose writable data shares a 16 KB page with its
    /// code (Flipper's libevent, for one): it moves the data so macOS can map the library. Experimental in the engine,
    /// so it is only added once an app has crashed for want of it (Workbench.retryMovingSharedData).
    static let moveSharedData = "--move-shared-data"
    private static let moveSharedDataKey = "MoveSharedDataAPKs"

    /// Whether a loose APK (one no repository launches) crashed for want of `--move-shared-data` before.
    static func movesSharedData(_ apk: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: moveSharedDataKey) ?? []).contains(apk.resolvingSymlinksInPath().path)
    }

    /// Remembers that a loose APK needs `--move-shared-data`, for its later launches.
    static func rememberMovesSharedData(_ apk: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: moveSharedDataKey) ?? []
        let path = apk.resolvingSymlinksInPath().path
        guard !paths.contains(path) else { return }
        paths.append(path)
        UserDefaults.standard.set(Array(paths.suffix(200)), forKey: moveSharedDataKey)
    }

    // MARK: Options

    /// Splits a line as a shell would into words: spaces separate, single and double quotes group, a backslash
    /// escapes the next character. Nothing is expanded.
    static func tokens(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped { word.append(ch); escaped = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { word.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; inWord = true; continue }
            if ch.isWhitespace {
                if inWord { words.append(word); word = ""; inWord = false }
                continue
            }
            word.append(ch); inWord = true
        }
        if inWord { words.append(word) }
        return words
    }

    /// The person's options without the reserved ones (and their values), and what was dropped. A token that is an
    /// APK path is dropped too: the build is what runs.
    static func sanitized(_ words: [String]) -> (kept: [String], dropped: [String]) {
        var kept: [String] = []
        var dropped: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let flag = w.split(separator: "=", maxSplits: 1).first.map(String.init) ?? w
            if let n = reserved[flag] {
                let takes = w.contains("=") ? 0 : n
                dropped.append(([w] + words.dropFirst(i + 1).prefix(takes)).joined(separator: " "))
                i += 1 + takes
                continue
            }
            if !w.hasPrefix("-"), w.lowercased().hasSuffix(".apk"), !(kept.last.map { $0.hasPrefix("-") && !$0.contains("=") } ?? false) {
                dropped.append(w); i += 1; continue
            }
            kept.append(w); i += 1
        }
        return (kept, dropped)
    }

    /// What `ws` adds to a launch: `--skin NAME` (with its device, so the rest of Greenroom knows the device's kind,
    /// unless the person's own options name one), then the person's own options. Placed before a caller's own options,
    /// so an agent's `device` or a matrix cell still wins.
    static func options(for ws: Workspace?) -> [String] {
        guard let ws else { return [] }
        let own = sanitized(tokens(ws.launchOptions)).kept
        var out: [String] = []
        let skin = ws.skin.trimmingCharacters(in: .whitespaces)
        if !skin.isEmpty, !own.contains("--skin") {
            out += ["--skin", skin]
            if !own.contains("--device"), let d = cachedSkins.first(where: { $0.name == skin })?.device, !d.isEmpty {
                out += ["--device", d]
            }
        }
        return out + own
    }

    /// What `ws` adds to a walk's launches and a comparison's: the same, less `--appearance` (a walk captures the
    /// appearances its matrix names, a change tour is light).
    static func walkOptions(for ws: Workspace?) -> [String] { withoutAppearance(options(for: ws)) }

    /// The part of a map's profile (MapProfile.launch) that says how its walk launched, nil when plainly. Made from
    /// the stored settings alone (not the skin's resolved device), so it stays the same from one walk to the next.
    static func walkKey(for ws: Workspace?) -> String? {
        guard let ws else { return nil }
        let skin = ws.skin.trimmingCharacters(in: .whitespaces)
        let words = (skin.isEmpty ? [] : ["--skin", skin]) + withoutAppearance(sanitized(tokens(ws.launchOptions)).kept)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func withoutAppearance(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            if words[i] == "--appearance" { i += 2; continue }
            if words[i].hasPrefix("--appearance=") { i += 1; continue }
            out.append(words[i]); i += 1
        }
        return out
    }

    // MARK: Skins

    /// The skins listed last (empty until `loadSkins` has run once).
    private(set) static var cachedSkins: [Skin] = []

    /// Lists the engine's stored skins (its built-in ones and any added to Greenroom's engine state), off the main
    /// thread; `done` gets them on the main thread.
    static func loadSkins(_ done: (([Skin]) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, out) = runSkin(["list", "--json"])
            let skins = status == 0 ? ((try? JSONDecoder().decode([Skin].self, from: Data(out.utf8))) ?? []) : []
            DispatchQueue.main.async {
                if status == 0 { cachedSkins = skins }
                done?(status == 0 ? skins : cachedSkins)
            }
        }
    }

    /// Adds a skin from a folder (skin.json and its images) or a zip of one, replacing one of the same name. `done`
    /// gets nil, or what the engine said went wrong, on the main thread.
    static func addSkin(from url: URL, _ done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, out) = runSkin(["add", "--from", url.path, "--force"])
            DispatchQueue.main.async {
                if status == 0 { loadSkins { _ in done(nil) } }
                else { done(out.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")) }
            }
        }
    }

    /// Asks for a skin folder or zip and adds it; `done` gets the new skin's name (the folder's or zip's), or nil.
    static func chooseAndAddSkin(for window: NSWindow?, _ done: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Choose a skin: a folder with skin.json and its frame image, or a zip of one (apksim docs/skins.md)."
        panel.prompt = "Add Skin"
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { done(nil); return }
            addSkin(from: url) { problem in
                if let problem {
                    let alert = NSAlert()
                    alert.messageText = "\(url.lastPathComponent) could not be added as a skin"
                    alert.informativeText = problem
                    alert.runModal()
                    done(nil)
                    return
                }
                // The engine names the skin from its skin.json; the newest match by folder name is the best guess.
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                done(cachedSkins.first(where: { $0.name == base })?.name)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private static func runSkin(_ args: [String]) -> (Int32, String) {
        let engine = Engine.shared
        guard (try? engine.prepare()) != nil else { return (-1, "The simulator engine is missing.") }
        let p = Process()
        p.executableURL = engine.launcher
        p.arguments = ["skin"] + args
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = engine.engineState.path
        p.environment = env
        p.currentDirectoryURL = engine.engineState
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "The simulator engine could not be started.") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// The sheet that sets a repository's skin and launch options: shown when a repository is first added (before its
/// first simulator starts) and from its + menu.
final class LaunchSettingsSheet: NSObject {
    private let alert = NSAlert()
    private let skinPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let optionsField = NSTextField(frame: .zero)
    private let note = NSTextField(wrappingLabelWithString: "")
    private weak var window: NSWindow?
    private var keepAlive: LaunchSettingsSheet?

    /// Shows the sheet for `ws` on `window`; `save` gets the chosen skin ("" for none) and options line.
    /// `finished` runs after either button, once `save` (Save only) has.
    static func present(for ws: Workspace, firstTime: Bool, on window: NSWindow, save: @escaping (_ skin: String, _ options: String) -> Void,
                        finished: (() -> Void)? = nil) {
        let sheet = LaunchSettingsSheet()
        sheet.window = window
        sheet.keepAlive = sheet
        sheet.run(ws, firstTime: firstTime, save: save, finished: finished)
    }

    private func run(_ ws: Workspace, firstTime: Bool, save: @escaping (String, String) -> Void, finished: (() -> Void)?) {
        let name = ws.root.lastPathComponent
        alert.messageText = firstTime ? "How should \(name) launch?" : "Launch Options for \(name)"
        alert.informativeText = firstTime
            ? "Pick a device skin and any extra apksim options before \(name)'s first simulator starts. You can change them later from its + menu or in Settings."
            : "Used by every simulator Greenroom starts for \(name): main, its sessions and pull requests. A running simulator takes them when it next launches."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: firstTime ? "Use Defaults" : "Cancel")

        skinPopup.target = self
        skinPopup.action = #selector(skinPicked)
        fillSkins(LaunchSettings.cachedSkins, selected: ws.skin)
        LaunchSettings.loadSkins { [weak self] skins in self?.fillSkins(skins, selected: self?.selectedSkin ?? ws.skin) }

        optionsField.stringValue = ws.launchOptions
        optionsField.placeholderString = "e.g. --appearance dark --locale de-DE --move-shared-data"
        optionsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        optionsField.target = self
        optionsField.action = #selector(optionsEdited)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.stringValue = Self.help
        note.preferredMaxLayoutWidth = 380

        let skinLabel = NSTextField(labelWithString: "Skin")
        let optionsLabel = NSTextField(labelWithString: "apksim options")
        for l in [skinLabel, optionsLabel] { l.font = .systemFont(ofSize: 11, weight: .medium); l.textColor = .secondaryLabelColor }
        let stack = NSStackView(views: [skinLabel, skinPopup, optionsLabel, optionsField, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: skinPopup)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 150)
        for v in [skinPopup, optionsField, note] { v.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = skinPopup

        guard let window else { keepAlive = nil; finished?(); return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { finished?(); return }
            defer { self.keepAlive = nil; finished?() }
            guard response == .alertFirstButtonReturn else { return }
            save(self.selectedSkin, self.optionsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static let help = "Greenroom keeps --headless, --control, --window and --data-slots to itself; anything else apksim takes (--device, --appearance, --locale, --network-profile, --move-shared-data, --jvm…) is passed on."
    private static let addTag = "__add__"

    private var selectedSkin: String {
        let v = skinPopup.selectedItem?.representedObject as? String ?? ""
        return v == Self.addTag ? "" : v
    }

    private func fillSkins(_ skins: [LaunchSettings.Skin], selected: String) {
        skinPopup.removeAllItems()
        skinPopup.addItem(withTitle: "None (plain screen)")
        skinPopup.lastItem?.representedObject = ""
        var names = skins.map(\.name)
        for s in skins {
            skinPopup.addItem(withTitle: s.label)
            skinPopup.lastItem?.representedObject = s.name
        }
        if !selected.isEmpty, !names.contains(selected) {   // stored, but the engine does not list it (yet)
            skinPopup.addItem(withTitle: "\(selected) (not found)")
            skinPopup.lastItem?.representedObject = selected
            names.append(selected)
        }
        skinPopup.menu?.addItem(.separator())
        skinPopup.addItem(withTitle: "Add Skin from Folder or Zip…")
        skinPopup.lastItem?.representedObject = Self.addTag
        skinPopup.selectItem(at: max(0, skinPopup.indexOfItem(withRepresentedObject: selected)))
    }

    @objc private func skinPicked() {
        guard skinPopup.selectedItem?.representedObject as? String == Self.addTag else { return }
        skinPopup.selectItem(at: 0)
        LaunchSettings.chooseAndAddSkin(for: nil) { [weak self] name in
            guard let self else { return }
            self.fillSkins(LaunchSettings.cachedSkins, selected: name ?? "")
        }
    }

    @objc private func optionsEdited() {
        let dropped = LaunchSettings.sanitized(LaunchSettings.tokens(optionsField.stringValue)).dropped
        note.stringValue = dropped.isEmpty ? Self.help : "Left out (Greenroom sets these itself): " + dropped.joined(separator: ", ")
        note.textColor = dropped.isEmpty ? .secondaryLabelColor : .systemOrange
    }
}
