import AppKit
import SwiftUI

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

/// Frosted-glass Matrix Wall configurator sheet with axis chips, presets, and a live wall preview.
enum MatrixSheet {
    static func ask(over window: NSWindow, apkName: String, done: @escaping (Matrix) -> Void) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.backgroundColor = Design.stage
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.isReleasedWhenClosed = false

        let view = MatrixConfiguratorView(apkName: apkName, onCancel: {
            window.endSheet(sheet, returnCode: .cancel)
        }, onRun: { matrix in
            window.endSheet(sheet, returnCode: .OK)
            done(matrix)
        })
        sheet.contentView = NSHostingView(rootView: view)
        window.beginSheet(sheet) { _ in sheet.orderOut(nil) }
    }
}

private struct MatrixConfiguratorView: View {
    let apkName: String
    let onCancel: () -> Void
    let onRun: (Matrix) -> Void

    @State private var devices: Set<String> = ["phone"]
    @State private var appearances: Set<String> = ["light", "dark"]
    @State private var locales: Set<String> = ["en-US"]
    @State private var fontScales: Set<String> = ["1.0"]

    private var currentMatrix: Matrix {
        var m = Matrix()
        m.devices = Matrix.devices.map(\.0).filter { devices.contains($0) }
        m.appearances = Matrix.appearances.map(\.0).filter { appearances.contains($0) }
        m.locales = Matrix.locales.map(\.0).filter { locales.contains($0) }
        m.fontScales = Matrix.fontScales.map(\.0).filter { fontScales.contains($0) }
        return m
    }

    private var cells: [Matrix.Cell] { currentMatrix.cells }
    private var canRun: Bool { !cells.isEmpty && cells.count <= Matrix.maxCells }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Matrix Wall")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SettingsTheme.ink)
                        Text(apkName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(SettingsTheme.mute)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
                    }
                    Text("Every combination runs side by side with mirrored touch (up to \(Matrix.maxCells)).")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.mute)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsTheme.mute)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }

            // Quick presets
            HStack(spacing: 6) {
                Text("Presets:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsTheme.mute)
                presetChip("Light × Dark") {
                    devices = ["phone"]; appearances = ["light", "dark"]; locales = ["en-US"]; fontScales = ["1.0"]
                }
                presetChip("RTL + 200% Text") {
                    devices = ["phone"]; appearances = ["dark"]; locales = ["en-US", "ar-EG"]; fontScales = ["1.0", "2.0"]
                }
                presetChip("Form Factors") {
                    devices = ["phone", "foldable", "tablet"]; appearances = ["light", "dark"]; locales = ["en-US"]; fontScales = ["1.0"]
                }
            }

            // Axis chips
            VStack(alignment: .leading, spacing: 10) {
                axisRow("DEVICES", Matrix.devices, selection: $devices)
                axisRow("APPEARANCE", Matrix.appearances, selection: $appearances)
                axisRow("LANGUAGE", Matrix.locales, selection: $locales)
                axisRow("TEXT SIZE", Matrix.fontScales, selection: $fontScales)
            }

            // Live grid preview
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Live Wall Preview")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SettingsTheme.mute)
                    Spacer()
                    Text(cells.isEmpty
                         ? "Choose at least one of each"
                         : "\(cells.count) / \(Matrix.maxCells) simulator\(cells.count == 1 ? "" : "s")" + (cells.count > Matrix.maxCells ? " (too many)" : ""))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(canRun ? SettingsTheme.accent : SettingsTheme.record)
                }

                let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(Array(cells.prefix(16).enumerated()), id: \.offset) { _, cell in
                        let isDark = cell.options.contains("dark")
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isDark ? SettingsTheme.accent.opacity(0.35) : Color.black.opacity(0.22))
                                .frame(width: 14, height: 22)
                            Text(cell.label)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(isDark ? SettingsTheme.ink : Color(white: 0.12))
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isDark ? Color(red: 0.11, green: 0.12, blue: 0.15) : Color(red: 0.92, green: 0.93, blue: 0.95))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(SettingsTheme.stroke, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SettingsTheme.wellFill))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsTheme.ink)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.09)))
                    .keyboardShortcut(.cancelAction)

                Button(canRun ? "Launch \(cells.count) Simulator\(cells.count == 1 ? "" : "s")" : "Cannot Launch") {
                    onRun(currentMatrix)
                }
                .buttonStyle(.plain)
                .disabled(!canRun)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsTheme.onAccent)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.accent.opacity(canRun ? 1 : 0.35)))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(SettingsTheme.stage)
        .preferredColorScheme(.dark)
    }

    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SettingsTheme.ink)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(SettingsTheme.stroke, lineWidth: 1))
    }

    private func axisRow(_ title: String, _ values: [(String, String)], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SettingsTheme.mute)
            HStack(spacing: 6) {
                ForEach(values, id: \.0) { value, name in
                    let on = selection.wrappedValue.contains(value)
                    Button(name) {
                        if on && selection.wrappedValue.count > 1 {
                            selection.wrappedValue.remove(value)
                        } else {
                            selection.wrappedValue.insert(value)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? SettingsTheme.accent : SettingsTheme.mute)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? SettingsTheme.accent.opacity(0.16) : Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(on ? SettingsTheme.accent.opacity(0.55) : SettingsTheme.stroke, lineWidth: 1)
                    )
                }
            }
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
