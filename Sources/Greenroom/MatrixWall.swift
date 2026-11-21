import AppKit

/// The matrix wall (docs/PLAN.md, phase 4): one build over devices × appearances × locales × font scales, every
/// combination a live simulator side by side, one touch going to all of them. Each cell runs at a low frame rate
/// (`--max-fps`); the one under the pointer runs at full rate, so a wall of twelve costs about what two do.
struct Matrix {
    static let devices: [(String, String)] = [("phone", "Phone"), ("foldable", "Foldable"), ("tablet", "Tablet")]
    static let appearances: [(String, String)] = [("light", "Light"), ("dark", "Dark")]
    static let locales: [(String, String)] = [("en-US", "English"), ("de-DE", "German"), ("ar-EG", "Arabic (RTL)"), ("ja-JP", "Japanese")]
    static let fontScales: [(String, String)] = [("1.0", "Text 100%"), ("1.3", "Text 130%"), ("2.0", "Text 200%")]
    static let maxCells = 16
    static let idleFps = 12, hoverFps = 120

    var devices: [String] = ["phone"]
    var appearances: [String] = ["light", "dark"]
    var locales: [String] = ["en-US"]
    var fontScales: [String] = ["1.0"]

    struct Cell { let label: String; let options: [String] }

    var cells: [Cell] {
        var out: [Cell] = []
        for d in devices { for a in appearances { for l in locales { for f in fontScales {
            var opts = ["--device", d, "--appearance", a, "--locale", l, "--max-fps", String(Self.idleFps)]
            if f != "1.0" { opts += ["--font-scale", f] }
            func name(_ list: [(String, String)], _ v: String) -> String { list.first { $0.0 == v }?.1 ?? v }
            // Only the axes that vary are named: "Dark · German" says more than a full list repeated on every cell.
            var parts: [String] = []
            if devices.count > 1 { parts.append(name(Self.devices, d)) }
            if appearances.count > 1 { parts.append(name(Self.appearances, a)) }
            if locales.count > 1 { parts.append(name(Self.locales, l)) }
            if fontScales.count > 1 { parts.append(name(Self.fontScales, f)) }
            out.append(Cell(label: parts.isEmpty ? "Matrix" : parts.joined(separator: " · "), options: opts))
        } } } }
        return out
    }
}

/// Asks which values of each axis to run; answers the matrix, or nil when cancelled.
enum MatrixSheet {
    static func ask(over window: NSWindow, apkName: String, done: @escaping (Matrix) -> Void) {
        var m = Matrix()
        let alert = NSAlert()
        alert.messageText = "Matrix wall for \(apkName)"
        alert.informativeText = "Every combination runs at once, side by side; a touch on one goes to all of them. Up to \(Matrix.maxCells)."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        var boxes: [(String, String, NSButton)] = []
        func row(_ title: String, _ axis: String, _ values: [(String, String)], _ on: [String]) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            let line = NSStackView()
            line.spacing = 10
            for (v, name) in values {
                let b = NSButton(checkboxWithTitle: name, target: nil, action: nil)
                b.state = on.contains(v) ? .on : .off
                line.addArrangedSubview(b)
                boxes.append((axis, v, b))
            }
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(line)
        }
        row("Devices", "device", Matrix.devices, m.devices)
        row("Appearance", "appearance", Matrix.appearances, m.appearances)
        row("Language", "locale", Matrix.locales, m.locales)
        row("Text size", "font", Matrix.fontScales, m.fontScales)
        let count = NSTextField(labelWithString: "")
        count.textColor = .secondaryLabelColor
        stack.addArrangedSubview(count)
        func read() -> Matrix {
            var r = Matrix()
            func on(_ axis: String) -> [String] { boxes.filter { $0.0 == axis && $0.2.state == .on }.map(\.1) }
            r.devices = on("device"); r.appearances = on("appearance"); r.locales = on("locale"); r.fontScales = on("font")
            return r
        }
        let runButton = alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        final class Updater: NSObject { var f: () -> Void = {}; @objc func changed(_ s: Any?) { f() } }
        let updater = Updater()
        updater.f = {
            let n = read().cells.count
            count.stringValue = n == 0 ? "Choose at least one of each." : "\(n) simulator\(n == 1 ? "" : "s")" + (n > Matrix.maxCells ? ": too many (at most \(Matrix.maxCells))" : "")
            runButton.isEnabled = n > 0 && n <= Matrix.maxCells
        }
        for (_, _, b) in boxes { b.target = updater; b.action = #selector(Updater.changed(_:)) }
        updater.f()
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { answer in
            withExtendedLifetime(updater) {}
            m = read()
            if answer == .alertFirstButtonReturn, !m.cells.isEmpty, m.cells.count <= Matrix.maxCells { done(m) }
        }
    }
}

extension Workbench {
    /// Greenroom > Device > Matrix Wall…: asks for the axes, then runs the chosen simulator's APK in every combination.
    @objc func showMatrix(_ sender: Any?) {
        guard let apk = selected?.apk ?? Recents.all.first else {
            NSAlert.informational("Open an APK first: the matrix wall runs the one you are looking at.").beginSheetModal(for: window)
            return
        }
        MatrixSheet.ask(over: window, apkName: apk.deletingPathExtension().lastPathComponent) { [weak self] m in
            self?.runMatrix(m, apk: apk)
        }
    }

    /// Starts every cell (the simulators already running stay), side by side with input mirrored to all.
    func runMatrix(_ matrix: Matrix, apk: URL, done: (([Simulator]) -> Void)? = nil) {
        closeMatrix(nil)
        matrixGeneration += 1
        let cells = matrix.cells
        guard !cells.isEmpty else { done?([]); return }
        beforeMatrix = (sideBySide, mirror)
        for cell in cells {
            guard let sim = open(apk, remember: false, options: cell.options, fromAgent: true) else { continue }
            sim.cellLabel = cell.label
            matrixSims.append(sim)
        }
        if let sim = matrixSims.first { select(sim) }
        setSideBySide(true)
        setMirror(true)
        done?(matrixSims)
    }

    /// Quits the matrix's simulators (ended ones too, so their tiles go), and puts side by side and mirroring back.
    @objc func closeMatrix(_ sender: Any?) {
        matrixGeneration += 1
        let sims = matrixSims
        matrixSims = []
        for sim in sims { Engine.shared.close(sim) }
        if let before = beforeMatrix {
            beforeMatrix = nil
            setMirror(before.mirror)
            setSideBySide(before.sideBySide)
        }
    }

    /// A cell relaunched (adb, the debugger, a network recording turned on) keeps its place, caption and rate.
    func matrixReplaced(_ old: Simulator, with new: Simulator) {
        guard let i = matrixSims.firstIndex(where: { $0 === old }) else { return }
        new.cellLabel = old.cellLabel
        matrixSims[i] = new
    }

    /// The pointer came onto (or left) a matrix cell: that one draws at full rate meanwhile.
    func matrixHover(_ sim: Simulator, inside: Bool) {
        guard matrixSims.contains(where: { $0 === sim }), sim.state == .running else { return }
        sim.send("maxfps \(inside ? Matrix.hoverFps : Matrix.idleFps)")
    }
}

private extension NSAlert {
    static func informational(_ text: String) -> NSAlert {
        let a = NSAlert(); a.messageText = text; a.alertStyle = .informational; return a
    }
}
