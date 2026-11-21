import AppKit
import Darwin

/// How much memory the running simulators take, read every few seconds while any runs: each engine process's
/// physical footprint (what Activity Monitor's Memory column shows), plus Greenroom's own. Read from this side with
/// `proc_pid_rusage`, so the engines are asked nothing after their process id (`stats`, once each).
final class MemoryMeter {
    struct Reading {
        var simulatorsMB: Double, appMB: Double, count: Int
        var totalMB: Double { simulatorsMB + appMB }
    }

    var onReading: ((Reading) -> Void)?
    private var timer: Timer?
    private var pids: [ObjectIdentifier: Int32] = [:]
    /// A simulator whose process cannot be read from here: its own `stats` figure, asked each time.
    private var fromStats: [ObjectIdentifier: Double] = [:]
    private var asking: Set<ObjectIdentifier> = []

    /// Starts or stops reading as simulators come and go.
    func watch(_ sims: [Simulator]) {
        let alive = sims.filter(\.isAlive)
        let ids = Set(alive.map(ObjectIdentifier.init))
        pids = pids.filter { ids.contains($0.key) }
        fromStats = fromStats.filter { ids.contains($0.key) }
        if alive.isEmpty {
            timer?.invalidate()
            timer = nil
            onReading?(Reading(simulatorsMB: 0, appMB: PerfCheck.footprintMB(), count: 0))
        } else if timer == nil {
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.read() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
            read()
        }
    }

    private func read() {
        let sims = Engine.shared.simulators.filter { $0.isAlive && $0.state == .running }
        var total = 0.0
        for sim in sims {
            let id = ObjectIdentifier(sim)
            if let pid = pids[id] {
                if let mb = Self.footprintMB(pid: pid) { total += mb; continue }
                pids[id] = nil   // gone or not ours to read: ask the engine instead
            }
            if let mb = fromStats[id] { total += mb }
            guard !asking.contains(id) else { continue }
            asking.insert(id)
            sim.send("stats") { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.asking.remove(id)
                    var fields: [String: String] = [:]
                    for part in reply.split(separator: " ") {
                        let kv = part.split(separator: "=", maxSplits: 1)
                        if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
                    }
                    if let pid = fields["pid"].flatMap({ Int32($0) }), Self.footprintMB(pid: pid) != nil {
                        self.pids[id] = pid
                        self.fromStats[id] = nil
                    } else if let mb = fields["footprintMb"].flatMap(Double.init) {
                        self.fromStats[id] = mb
                    }
                }
            }
        }
        onReading?(Reading(simulatorsMB: total, appMB: PerfCheck.footprintMB(), count: sims.count))
    }

    static func footprintMB(pid: Int32) -> Double? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : nil
    }
}

/// The memory reading, small, in the stage's top left corner: shown only once the simulators and Greenroom
/// together take a lot (2 GB, or a fifth of the Mac's memory if that is less), in the warning colour past half of it.
final class MemoryLabel: NSTextField {
    private static let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
    static var showAtMB: Double {
        if let mb = ProcessInfo.processInfo.environment["GREENROOM_MEMORY_LABEL_MB"].flatMap(Double.init) { return mb }   // checks
        return min(2048, physicalMB * 0.2)
    }
    private(set) var shown = false

    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        alphaValue = 0
        isHidden = true
        setAccessibilityRole(.staticText)
    }

    func show(_ r: MemoryMeter.Reading) {
        // A little below the threshold before it goes, so a figure hovering around it does not blink.
        let on = r.count > 0 && (shown ? r.totalMB >= Self.showAtMB * 0.9 : r.totalMB >= Self.showAtMB)
        if on {
            let heavy = r.totalMB >= Self.physicalMB * 0.5
            let text = NSMutableAttributedString(string: "Memory ", attributes: [.foregroundColor: Design.mute])
            text.append(NSAttributedString(string: Self.format(r.totalMB), attributes: [.foregroundColor: heavy ? Design.warning : Design.ink]))
            attributedStringValue = text
            toolTip = "\(r.count) simulator\(r.count == 1 ? "" : "s"): \(Self.format(r.simulatorsMB)), Greenroom: \(Self.format(r.appMB)), of \(Self.format(Self.physicalMB)) in this Mac"
            setAccessibilityLabel("Memory in use: \(Self.format(r.totalMB))")
            superview?.needsLayout = true
        }
        guard on != shown else { return }
        shown = on
        if on { isHidden = false }
        Design.animate(Design.arrive, { self.animator().alphaValue = on ? 1 : 0 }, done: { if !self.shown { self.isHidden = true } })
    }

    static func format(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
