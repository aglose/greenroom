import Foundation

/// App data kept per device: a simulator opened plainly (dropped, from ⌘O or the recent list, Open Beside As, an agent's
/// launch outside a worktree) keeps its app's data in a slot named for the device it was opened as (`gdphone`,
/// `gdtablet`...). Sign in once on a phone and every later phone of that app starts signed in, across restarts of the
/// simulator and of Greenroom.
///
/// - A second copy of the same APK on the same device while the first still runs starts from a clone of the device's
///   data (`gc...`): two processes cannot share one slot, and the clone goes when the copy has exited. What the copy
///   changes is not kept.
/// - A fresh launch (`--fresh`) runs on a throwaway slot (`gf...`), so it never erases the device's data.
/// - A session's simulator keeps its own slot (`--data-slots gr...`, SessionStore) and is not touched here.
/// - The first time a device slot is used, each app's data from before (the engine's `default` slot) is cloned into it,
///   so nobody is signed out by the change.
enum DeviceData {
    static let devicePrefix = "gd"
    static let clonePrefix = "gc"
    static let freshPrefix = "gf"

    /// The slot of the device `options` launch as (phone when they name none). Letters and digits only.
    static func slot(for options: [String]) -> String {
        let device = DevHooks.value("--device", in: options) ?? "phone"
        let clean = String(device.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init).prefix(24))
        return devicePrefix + (clean.isEmpty ? "phone" : clean)
    }

    /// Whether a slot name is one of the throwaway kinds made here.
    static func isThrowaway(_ slot: String?) -> Bool {
        guard let slot else { return false }
        return slot.hasPrefix(clonePrefix) || slot.hasPrefix(freshPrefix)
    }

    /// Whether `slot` is one of the kinds made here (device, clone, fresh): Open Beside As drops it and picks again.
    static func isOurs(_ slot: String?) -> Bool {
        guard let slot else { return false }
        return slot.hasPrefix(devicePrefix) || isThrowaway(slot)
    }

    /// The options a plain launch of `apk` gets: unchanged when they already name a slot, else the device's slot (or a
    /// clone of it, or a fresh throwaway one) put first. `others`: the simulators on the stage and those still exiting.
    static func options(for apk: URL, _ options: [String], others: [Simulator], root: URL) -> [String] {
        if options.contains("--data-slots") { return options }
        if options.contains("--fresh") { return ["--data-slots", freshPrefix + random()] + options }
        let slot = slot(for: options)
        adoptDefault(into: slot, in: root)
        let same = apk.standardizedFileURL.path
        let busy = others.contains { $0.apk.standardizedFileURL.path == same && DevHooks.value("--data-slots", in: $0.options) == slot }
        if busy, case .cloned(let name) = SlotClone.make(slot: slot, in: root, prefix: clonePrefix) {
            return ["--data-slots", name] + options
        }
        // Not busy, or nothing to clone yet: the device's own slot (the engine takes its next instance if it is held).
        return ["--data-slots", slot] + options
    }

    /// Clones each app's `default` data into `<slot>-0` where that does not exist yet (data from before device slots).
    static func adoptDefault(into slot: String, in root: URL) {
        let fm = FileManager.default
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let from = pkg.appendingPathComponent("default", isDirectory: true)
            let to = pkg.appendingPathComponent(slot + "-0", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue,
                  !fm.fileExists(atPath: to.path), !inUse(from) else { continue }
            for suffix in ["", ".device"] {
                let a = pkg.appendingPathComponent("default" + suffix), b = pkg.appendingPathComponent(slot + "-0" + suffix)
                guard fm.fileExists(atPath: a.path) else { continue }
                if clonefile(a.path, b.path, 0) != 0 { try? fm.copyItem(at: a, to: b) }
            }
        }
    }

    /// Removes a throwaway slot once no simulator uses it: called when one has ended. Waits a little first, as a
    /// relaunch (same options, same slot) starts its new simulator only after the old one has exited.
    static func release(_ sim: Simulator) {
        guard let slot = DevHooks.value("--data-slots", in: sim.options), isThrowaway(slot) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let engine = Engine.shared
            let used = (engine.simulators + engine.closing).contains { $0.isAlive && DevHooks.value("--data-slots", in: $0.options) == slot }
            guard !used else { return }
            let root = engine.engineState.appendingPathComponent("cache/data", isDirectory: true)
            DispatchQueue.global(qos: .utility).async { remove(slot, in: root) }
        }
    }

    /// Throwaway slots an earlier run left behind (the app quit or crashed with a copy running). Only when nothing of
    /// this app runs; a slot an engine still holds is never touched.
    static func sweep(in root: URL) {
        let fm = FileManager.default
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for e in (try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? [] {
                let name = e.lastPathComponent
                guard name.hasPrefix(clonePrefix) || name.hasPrefix(freshPrefix), !name.hasSuffix(".device") else { continue }
                guard !inUse(e) else { continue }
                try? fm.removeItem(at: e)
                try? fm.removeItem(at: pkg.appendingPathComponent(name + ".device"))
            }
        }
    }

    /// Every folder of `slot` (`<slot>-N`, `<slot>-N.device`) in every package, unless an engine holds it.
    private static func remove(_ slot: String, in root: URL) {
        let fm = FileManager.default
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for e in (try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? [] where e.lastPathComponent.hasPrefix(slot + "-") {
                let data = e.lastPathComponent.hasSuffix(".device") ? pkg.appendingPathComponent(String(e.lastPathComponent.dropLast(7))) : e
                guard !inUse(data) else { continue }
                try? fm.removeItem(at: e)
            }
        }
    }

    /// Whether a running engine holds the slot folder: each holds a lock on its `.lock` (as the engine's ctl.py tests).
    static func inUse(_ slotFolder: URL) -> Bool {
        let fd = open(slotFolder.appendingPathComponent(".lock").path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if lockf(fd, F_TLOCK, 0) == 0 { _ = lockf(fd, F_ULOCK, 0); return false }
        return true
    }

    private static func random() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }
}
