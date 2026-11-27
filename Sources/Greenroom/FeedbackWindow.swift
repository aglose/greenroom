import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug, crash, suggestion
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: "Bug / Problem"
        case .crash: "Crash"
        case .suggestion: "Suggestion"
        }
    }

    var symbol: String {
        switch self {
        case .bug: "ladybug"
        case .crash: "exclamationmark.triangle"
        case .suggestion: "lightbulb"
        }
    }

    var gitHubLabel: String {
        switch self {
        case .bug, .crash: "bug"
        case .suggestion: "enhancement"
        }
    }
}

struct FeedbackScreenshot: Identifiable {
    let id = UUID()
    let name: String
    let image: NSImage
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Pure formatting, environment collection, and URL/file helpers for Report Feedback.
enum FeedbackBuilder {
    static let newIssueBaseURL = "https://github.com/aglose/greenroom/issues/new"
    /// Stay comfortably below GitHub's ~8 KB URL limit.
    static let maxEncodedURLLength = 7400

    static func systemInfo(runningSimulators: Int = Engine.shared.simulators.filter(\.isAlive).count) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let engine = Engine.shared.version
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = hardwareArch()
        let model = sysctlString("hw.model") ?? "Mac"
        var lines = [
            "- **Greenroom:** \(version) (build \(build))",
            "- **Engine (apksim):** \(engine)",
            "- **macOS:** \(macOS)",
            "- **Hardware:** \(model) (\(arch))",
        ]
        if runningSimulators > 0 {
            lines.append("- **Open simulators:** \(runningSimulators)")
        }
        return lines.joined(separator: "\n")
    }

    static func markdownBody(
        category: FeedbackCategory,
        description: String,
        includeSystemInfo: Bool,
        systemInfo: String,
        stacktrace: String,
        screenshotNames: [String]
    ) -> String {
        var sections: [String] = []
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            sections.append(trimmedDescription)
        } else {
            sections.append("_Describe what happened, what you expected, and steps to reproduce._")
        }

        if includeSystemInfo {
            let trimmedEnv = systemInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedEnv.isEmpty {
                sections.append("### Environment\n\n\(trimmedEnv)")
            }
        }

        let trimmedStack = stacktrace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStack.isEmpty {
            let heading = category == .crash ? "Stacktrace / Crash Details" : "Stacktrace / Additional Information"
            sections.append(
                """
                ### \(heading)

                <details>
                <summary>Expand details</summary>

                ```
                \(trimmedStack)
                ```

                </details>
                """
            )
        }

        if !screenshotNames.isEmpty {
            let list = screenshotNames.joined(separator: ", ")
            sections.append(
                """
                ### Screenshots

                <!-- Drag your screenshots from the revealed Finder folder here: \(list) -->
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }

    static func gitHubIssueURL(category: FeedbackCategory, title: String, body: String) -> (url: URL, truncated: Bool)? {
        func buildURL(with bodyText: String) -> URL? {
            var comps = URLComponents(string: newIssueBaseURL)
            var items: [URLQueryItem] = [
                URLQueryItem(name: "labels", value: category.gitHubLabel),
            ]
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                items.append(URLQueryItem(name: "title", value: trimmedTitle))
            }
            if !bodyText.isEmpty {
                items.append(URLQueryItem(name: "body", value: bodyText))
            }
            comps?.queryItems = items
            return comps?.url
        }

        guard let full = buildURL(with: body) else { return nil }
        if full.absoluteString.count <= maxEncodedURLLength {
            return (full, false)
        }

        let notice = "\n\n_(Report truncated to fit URL length — the full report was copied to your clipboard; paste to replace.)_"
        var low = 0
        var high = body.count
        var best: URL?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(body.prefix(mid)) + notice
            if let u = buildURL(with: candidate), u.absoluteString.count <= maxEncodedURLLength {
                best = u
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if let best { return (best, true) }
        return buildURL(with: notice.trimmingCharacters(in: .whitespacesAndNewlines)).map { ($0, true) }
    }

    /// Saves attached screenshots into a private folder under `Engine.shared.state/feedback/` so Finder can reveal them
    /// for drag-and-drop into the GitHub issue.
    static func stageScreenshots(_ screenshots: [FeedbackScreenshot]) -> [URL] {
        guard !screenshots.isEmpty else { return [] }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = Engine.shared.state
            .appendingPathComponent("feedback", isDirectory: true)
            .appendingPathComponent("Feedback-\(stamp.string(from: Date()))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return []
        }
        var urls: [URL] = []
        var usedNames: Set<String> = []
        for (index, shot) in screenshots.enumerated() {
            let base = sanitizeFilename(shot.name.isEmpty ? "screenshot-\(index + 1).png" : shot.name)
            var name = base.lowercased().hasSuffix(".png") ? base : "\(base).png"
            var suffix = 2
            while usedNames.contains(name) {
                let stem = (base as NSString).deletingPathExtension
                name = "\(stem)-\(suffix).png"
                suffix += 1
            }
            usedNames.insert(name)
            let file = folder.appendingPathComponent(name)
            if (try? shot.pngData.write(to: file, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                urls.append(file)
            }
        }
        return urls
    }

    /// Reads the tail of the active simulator's log (or the newest log in `Engine.shared.logs`).
    static func recentSimulatorLogTail(selected: Simulator?, maxLines: Int = 120, maxBytes: Int = 16_384) -> String? {
        let logURL: URL? = {
            if let log = selected?.log, FileManager.default.fileExists(atPath: log.path) {
                return log
            }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: Engine.shared.logs,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            return files
                .filter { $0.pathExtension == "log" }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }
                .first
        }()
        guard let logURL else { return nil }
        return readTail(of: logURL, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// Finds the newest Greenroom crash report (either queued in `Reports` or written by macOS in DiagnosticReports).
    static func latestCrashReport(maxLines: Int = 120, maxBytes: Int = 16_384) -> String? {
        if let queued = Reports.shared.waiting().reversed().first(where: { $0.1.contains("\"kind\" : \"crash\"") }) {
            return queued.1
        }
        let diagDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diagDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let newest = files
            .filter {
                let name = $0.lastPathComponent
                return name.hasPrefix("Greenroom") && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
            }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
        guard let newest else { return nil }
        return readHead(of: newest, maxLines: maxLines, maxBytes: maxBytes)
    }

    static func makeScreenshot(from image: NSImage, name: String) -> FeedbackScreenshot? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return FeedbackScreenshot(
            name: name,
            image: image,
            pngData: png,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh
        )
    }

    static func captureWindowImage(for window: NSWindow) -> NSImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if !locked,
           let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let capture = unsafeBitCast(sym, to: Capture.self)
            if let cg = capture(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        guard let view = window.contentView, let root = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.setFillColor(Design.stage.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { root.render(in: ctx) }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func readTail(of url: URL, maxLines: Int, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(maxLines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    private static func readHead(of url: URL, maxLines: Int, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(maxLines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : head
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "screenshot.png" : result
    }

    private static func hardwareArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// Help > Report Feedback…: dark-glass form for reporting issues or suggestions with optional system info,
/// stacktraces/logs, and screenshots. Opens a pre-filled GitHub issue or copies Markdown; never uploads silently.
final class FeedbackWindow: NSWindowController {
    static let shared = FeedbackWindow()
    private weak var workbench: Workbench?
    private let model = FeedbackViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Report Feedback"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Design.stage
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 540, height: 520)
        window.contentView = NSHostingView(rootView: FeedbackView(model: model))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(workbench: Workbench? = nil) {
        if let workbench { self.workbench = workbench }
        model.workbench = self.workbench
        model.refreshContext()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
private final class FeedbackViewModel: ObservableObject {
    weak var workbench: Workbench?

    @Published var category: FeedbackCategory = .bug
    @Published var title: String = ""
    @Published var details: String = ""
    @Published var includeSystemInfo: Bool = true
    @Published var systemInfo: String = ""
    @Published var stacktrace: String = ""
    @Published var stacktraceFromSimLog: Bool = false
    @Published var screenshots: [FeedbackScreenshot] = []
    @Published var hasSimulatorLog: Bool = false
    @Published var hasLatestCrash: Bool = false
    @Published var hasLiveSimulator: Bool = false
    @Published var capturingSimulator: Bool = false
    @Published var copied: Bool = false
    @Published var notice: (text: String, isWarning: Bool)?

    var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !stacktrace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !screenshots.isEmpty
    }

    func refreshContext() {
        systemInfo = FeedbackBuilder.systemInfo()
        hasLiveSimulator = workbench?.selected?.isAlive == true
        hasSimulatorLog = FeedbackBuilder.recentSimulatorLogTail(selected: workbench?.selected) != nil
        hasLatestCrash = FeedbackBuilder.latestCrashReport() != nil
    }

    func formattedMarkdown() -> String {
        FeedbackBuilder.markdownBody(
            category: category,
            description: details,
            includeSystemInfo: includeSystemInfo,
            systemInfo: systemInfo,
            stacktrace: stacktrace,
            screenshotNames: screenshots.map(\.name)
        )
    }

    func insertSimulatorLog() {
        guard let tail = FeedbackBuilder.recentSimulatorLogTail(selected: workbench?.selected) else {
            showNotice("No simulator log found yet.", isWarning: true)
            return
        }
        appendToStacktrace(tail)
        stacktraceFromSimLog = true
        showNotice("Inserted the latest simulator log lines. Review or redact before submitting.", isWarning: false)
    }

    func insertLatestCrash() {
        guard let crash = FeedbackBuilder.latestCrashReport() else {
            showNotice("No Greenroom crash report found.", isWarning: true)
            return
        }
        appendToStacktrace(crash)
        showNotice("Inserted the latest Greenroom crash report.", isWarning: false)
    }

    private func appendToStacktrace(_ text: String) {
        let existing = stacktrace.trimmingCharacters(in: .whitespacesAndNewlines)
        stacktrace = existing.isEmpty ? text : "\(existing)\n\n\(text)"
    }

    func captureWorkbenchWindow() {
        guard let win = workbench?.window else {
            showNotice("Greenroom window is not available to capture.", isWarning: true)
            return
        }
        guard let image = FeedbackBuilder.captureWindowImage(for: win),
              let shot = FeedbackBuilder.makeScreenshot(from: image, name: nextScreenshotName(prefix: "greenroom-window")) else {
            showNotice("Could not capture the Greenroom window.", isWarning: true)
            return
        }
        screenshots.append(shot)
        showNotice("Captured the Greenroom window.", isWarning: false)
    }

    func captureSimulator() {
        guard let sim = workbench?.selected, sim.isAlive else {
            showNotice("No running simulator to capture.", isWarning: true)
            return
        }
        capturingSimulator = true
        let dir = Engine.shared.screenshots
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent("feedback-\(UUID().uuidString).png")
        sim.send("shot screenshots/\(temp.lastPathComponent)") { [weak self] answer in
            Task { @MainActor in
                guard let self else { return }
                self.capturingSimulator = false
                defer { try? FileManager.default.removeItem(at: temp) }
                guard let data = try? Data(contentsOf: temp),
                      let image = NSImage(data: data),
                      let shot = FeedbackBuilder.makeScreenshot(from: image, name: self.nextScreenshotName(prefix: "simulator")) else {
                    let msg = answer.replacingOccurrences(of: "error: ", with: "")
                    self.showNotice("Simulator capture failed: \(msg.isEmpty ? "unknown error" : msg)", isWarning: true)
                    return
                }
                self.screenshots.append(shot)
                self.showNotice("Captured the running simulator.", isWarning: false)
            }
        }
    }

    func pickImageFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Attach"
        let response = panel.runModal()
        guard response == .OK else { return }
        addImageURLs(panel.urls)
    }

    func pasteImage() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let added = addImageURLs(urls)
            if added > 0 { return }
        }
        if let image = NSImage(pasteboard: pb),
           let shot = FeedbackBuilder.makeScreenshot(from: image, name: nextScreenshotName(prefix: "pasted")) {
            screenshots.append(shot)
            showNotice("Attached image from clipboard.", isWarning: false)
            return
        }
        showNotice("Clipboard does not contain an image.", isWarning: true)
    }

    @discardableResult
    func addImageURLs(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let shot = FeedbackBuilder.makeScreenshot(from: image, name: url.lastPathComponent) else { continue }
            screenshots.append(shot)
            added += 1
        }
        if added > 0 {
            showNotice(added == 1 ? "Attached 1 screenshot." : "Attached \(added) screenshots.", isWarning: false)
        }
        return added
    }

    func removeScreenshot(_ id: UUID) {
        screenshots.removeAll { $0.id == id }
    }

    func copyMarkdown() {
        let text = fullCopyableReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copied = false
        }
    }

    func openOnGitHub() {
        let body = formattedMarkdown()
        guard let result = FeedbackBuilder.gitHubIssueURL(category: category, title: title, body: body) else {
            showNotice("Could not build the GitHub issue link.", isWarning: true)
            return
        }

        if result.truncated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }

        let staged = FeedbackBuilder.stageScreenshots(screenshots)
        if !staged.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(staged)
        }

        NSWorkspace.shared.open(result.url)

        var notes = ["Opened GitHub in your browser."]
        if result.truncated {
            notes.append("The full report was copied to your clipboard.")
        }
        if !staged.isEmpty {
            notes.append("Screenshots were revealed in Finder — drag them into the issue.")
        }
        showNotice(notes.joined(separator: " "), isWarning: false)
    }

    private func fullCopyableReport() -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = formattedMarkdown()
        if trimmedTitle.isEmpty { return body }
        return "# \(trimmedTitle)\n\n\(body)"
    }

    private func nextScreenshotName(prefix: String) -> String {
        "\(prefix)-\(screenshots.count + 1).png"
    }

    private func showNotice(_ text: String, isWarning: Bool) {
        notice = (text, isWarning)
    }
}

private struct FeedbackView: View {
    @ObservedObject var model: FeedbackViewModel
    @State private var showEnvPreview = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(SettingsTheme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    categoryPicker
                    summaryCard
                    systemInfoCard
                    stacktraceCard
                    screenshotsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            if let notice = model.notice {
                noticeBanner(text: notice.text, isWarning: notice.isWarning)
            }

            Divider().overlay(SettingsTheme.stroke)
            footer
        }
        .background(SettingsTheme.stage)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsTheme.accent.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Report Feedback")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Text("Report an issue, crash, or suggestion for Greenroom.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsTheme.mute)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 14)
    }

    private var categoryPicker: some View {
        HStack(spacing: 8) {
            ForEach(FeedbackCategory.allCases) { cat in
                let selected = model.category == cat
                Button {
                    model.category = cat
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: cat.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(cat.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selected ? SettingsTheme.onAccent : SettingsTheme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? SettingsTheme.accent : Color.white.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(selected ? Color.clear : SettingsTheme.stroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var summaryCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Summary")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                TextField("Short title for the issue or problem", text: $model.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsTheme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Details")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.details)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsTheme.ink)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 90, maxHeight: 150)
                    if model.details.isEmpty {
                        Text("What happened? What did you expect? Steps to reproduce…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SettingsTheme.mute.opacity(0.65))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
            }
        }
    }

    private var systemInfoCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("System & app information")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsTheme.ink)
                        optionalBadge
                    }
                    Text("Greenroom, engine, and macOS versions. Never includes APK names, paths, or app data.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.mute)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $model.includeSystemInfo)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if model.includeSystemInfo {
                DisclosureGroup(isExpanded: $showEnvPreview) {
                    Text(model.systemInfo)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SettingsTheme.mute)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
                        .padding(.top, 4)
                } label: {
                    Text("Preview included information")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SettingsTheme.mute)
                }
            }
        }
    }

    private var stacktraceCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 8) {
                Text("Stacktrace or logs")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                optionalBadge
                Spacer()
                if model.hasSimulatorLog {
                    smallActionButton("Insert Simulator Log", symbol: "doc.text") {
                        model.insertSimulatorLog()
                    }
                }
                if model.hasLatestCrash {
                    smallActionButton("Insert Latest Crash", symbol: "bolt.horizontal") {
                        model.insertLatestCrash()
                    }
                }
                if !model.stacktrace.isEmpty {
                    smallActionButton("Clear", symbol: nil, destructive: true) {
                        model.stacktrace = ""
                        model.stacktraceFromSimLog = false
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.stacktrace)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SettingsTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 84, maxHeight: 150)
                if model.stacktrace.isEmpty {
                    Text("Paste a stacktrace, error output, or extra diagnostic details…")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(SettingsTheme.mute.opacity(0.65))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))

            if model.stacktraceFromSimLog {
                Text("Simulator logs may contain package names or output from the app you were running. Review or redact anything sensitive above.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.warning)
            }
        }
    }

    private var screenshotsCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 8) {
                Text("Screenshots")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                optionalBadge
                if !model.screenshots.isEmpty {
                    Text("\(model.screenshots.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SettingsTheme.mute)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08)))
                }
                Spacer()
            }

            HStack(spacing: 8) {
                smallActionButton("Capture Window", symbol: "macwindow") {
                    model.captureWorkbenchWindow()
                }
                if model.hasLiveSimulator {
                    smallActionButton(model.capturingSimulator ? "Capturing…" : "Capture Simulator", symbol: "iphone") {
                        model.captureSimulator()
                    }
                    .disabled(model.capturingSimulator)
                }
                smallActionButton("Add Image…", symbol: "photo.badge.plus") {
                    model.pickImageFiles()
                }
                smallActionButton("Paste Image", symbol: "doc.on.clipboard") {
                    model.pasteImage()
                }
                Spacer()
            }

            Group {
                if model.screenshots.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18))
                            .foregroundStyle(SettingsTheme.mute.opacity(0.7))
                        Text("Drop images here, paste from clipboard, or capture a screenshot")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.mute)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.screenshots) { shot in
                                screenshotThumbnail(shot)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(dropTargeted ? SettingsTheme.accent.opacity(0.12) : SettingsTheme.wellFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        dropTargeted ? SettingsTheme.accent : SettingsTheme.stroke,
                        style: StrokeStyle(lineWidth: 1, dash: model.screenshots.isEmpty ? [5, 4] : [])
                    )
            )
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }

            if !model.screenshots.isEmpty {
                Text("When you open GitHub, attached screenshots are saved locally and revealed in Finder so you can drag them into the issue.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsTheme.mute)
            }
        }
    }

    private func screenshotThumbnail(_ shot: FeedbackScreenshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: shot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 112, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(SettingsTheme.stroke, lineWidth: 1)
                    )
                Button {
                    model.removeScreenshot(shot.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, Color.black.opacity(0.75))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Remove screenshot")
            }
            Text(shot.name)
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsTheme.mute)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
        }
    }

    private func noticeBanner(text: String, isWarning: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isWarning ? SettingsTheme.warning : SettingsTheme.accent)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsTheme.mute)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background((isWarning ? SettingsTheme.warning : SettingsTheme.accent).opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Nothing is sent automatically. Opens a pre-filled GitHub issue.")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsTheme.mute)
            Spacer()
            Button(model.copied ? "Copied ✓" : "Copy Report") {
                model.copyMarkdown()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.copied ? SettingsTheme.accent : SettingsTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09)))
            .disabled(!model.canSubmit)
            .opacity(model.canSubmit ? 1 : 0.45)

            Button {
                model.openOnGitHub()
            } label: {
                HStack(spacing: 6) {
                    Text("Open on GitHub")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.onAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.accent))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSubmit)
            .opacity(model.canSubmit ? 1 : 0.45)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var optionalBadge: some View {
        Text("Optional")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(SettingsTheme.mute)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func smallActionButton(_ title: String, symbol: String?, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(destructive ? SettingsTheme.record : SettingsTheme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(destructive ? SettingsTheme.record.opacity(0.16) : Color.white.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        }
                        return item as? URL
                    }()
                    guard let url else { return }
                    Task { @MainActor in
                        model.addImageURLs([url])
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    Task { @MainActor in
                        if let shot = FeedbackBuilder.makeScreenshot(from: img, name: "dropped-\(model.screenshots.count + 1).png") {
                            model.screenshots.append(shot)
                        }
                    }
                }
            }
        }
        return handled
    }
}

/// `Greenroom --feedback-check`: headless self-check for FeedbackBuilder formatting, URL truncation, and screenshot staging.
enum FeedbackCheck {
    static func run() -> Never {
        var failures: [String] = []
        func expect(_ ok: Bool, _ msg: String) {
            if !ok { failures.append(msg) }
        }

        // 1. Minimal body: optional sections omitted.
        let minimal = FeedbackBuilder.markdownBody(
            category: .bug,
            description: "Button does not respond.",
            includeSystemInfo: false,
            systemInfo: "- **Greenroom:** 1.0",
            stacktrace: "   \n  ",
            screenshotNames: []
        )
        expect(minimal == "Button does not respond.", "minimal body should omit optional sections")

        // 2. Full body: all optional sections present.
        let env = FeedbackBuilder.systemInfo(runningSimulators: 2)
        expect(env.contains("Greenroom:") && env.contains("macOS:") && env.contains("Open simulators:** 2"),
               "systemInfo should include app, macOS, and simulator count")
        let full = FeedbackBuilder.markdownBody(
            category: .crash,
            description: "App crashed on rotate.",
            includeSystemInfo: true,
            systemInfo: env,
            stacktrace: "0   Greenroom   0x000100\n1   Greenroom   0x000200",
            screenshotNames: ["window-1.png", "sim-2.png"]
        )
        expect(full.contains("### Environment"), "full body should contain Environment")
        expect(full.contains("### Stacktrace / Crash Details"), "crash category should use Crash Details heading")
        expect(full.contains("0x000100"), "full body should include stacktrace")
        expect(full.contains("### Screenshots") && full.contains("window-1.png"), "full body should reference screenshots")

        // 3. Normal GitHub URL.
        if let normal = FeedbackBuilder.gitHubIssueURL(category: .suggestion, title: "Add dark mode", body: minimal) {
            expect(!normal.truncated, "short report should not be truncated")
            expect(normal.url.absoluteString.hasPrefix(FeedbackBuilder.newIssueBaseURL), "URL should target new issue page")
            expect(normal.url.absoluteString.contains("labels=enhancement"), "suggestion should carry enhancement label")
        } else {
            failures.append("normal gitHubIssueURL returned nil")
        }

        // 4. Oversized GitHub URL truncation.
        let huge = String(repeating: "frame 0xdeadbeef\n", count: 1200)
        if let big = FeedbackBuilder.gitHubIssueURL(category: .crash, title: "Crash", body: huge) {
            expect(big.truncated, "oversized report should be marked truncated")
            expect(big.url.absoluteString.count <= FeedbackBuilder.maxEncodedURLLength,
                   "truncated URL (\(big.url.absoluteString.count)) should stay within limit")
        } else {
            failures.append("oversized gitHubIssueURL returned nil")
        }

        // 5. Screenshot creation and staging with duplicate name deduplication.
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        if let s1 = FeedbackBuilder.makeScreenshot(from: img, name: "shot.png"),
           let s2 = FeedbackBuilder.makeScreenshot(from: img, name: "shot.png") {
            let staged = FeedbackBuilder.stageScreenshots([s1, s2])
            expect(staged.count == 2, "both screenshots should be staged")
            expect(Set(staged.map(\.lastPathComponent)).count == 2, "duplicate screenshot names should be deduplicated")
            expect(staged.allSatisfy { (try? Data(contentsOf: $0).count) ?? 0 > 0 }, "staged PNGs should be non-empty")
            if let dir = staged.first?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: dir)
            }
        } else {
            failures.append("makeScreenshot failed")
        }

        if failures.isEmpty {
            print("[greenroom] feedback-check: ok")
            exit(0)
        } else {
            for f in failures { print("[greenroom] feedback-check FAIL: \(f)") }
            exit(1)
        }
    }
}
