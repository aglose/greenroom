import Foundation

/// A saved flight recording (.apkrec) and what its manifest says about it.
struct Recording: Equatable {
    var url: URL
    var date: Date
    var size: Int
    var package: String?
    var apkName: String?
    /// Where the build was when the recording was saved, if the manifest has it and the file is still there.
    var apkPath: URL?
    var duration: TimeInterval?

    var name: String { url.deletingPathExtension().lastPathComponent }

    var meta: String {
        var parts = [Self.dateText.string(from: date)]
        if let duration { parts.append(duration < 90 ? "\(Int(duration.rounded())) s" : "\(Int((duration / 60).rounded())) min") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        return parts.joined(separator: "  ·  ")
    }

    private static let dateText: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Reads the recordings folder off the main thread. Manifests are read once per file (by modification time and size).
final class RecordingStore {
    private let queue = DispatchQueue(label: "greenroom.recordings", qos: .userInitiated)
    private var cache: [String: (Date, Int, Recording)] = [:]

    /// Calls `done` on the main queue with the recordings, newest first.
    func load(from folder: URL, done: @escaping ([Recording]) -> Void) {
        queue.async { [self] in
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            var found: [Recording] = []
            var seen = Set<String>()
            for f in files where f.pathExtension == "apkrec" {
                let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = v?.contentModificationDate ?? .distantPast
                let size = v?.fileSize ?? 0
                seen.insert(f.path)
                if let hit = cache[f.path], hit.0 == date, hit.1 == size { found.append(hit.2); continue }
                var r = Recording(url: f, date: date, size: size)
                if let m = Self.manifest(of: f) {
                    r.package = m["package"] as? String
                    r.apkName = m["apk"] as? String
                    if let p = m["apkPath"] as? String, fm.fileExists(atPath: p) { r.apkPath = URL(fileURLWithPath: p) }
                    // What a replay plays: from the checkpoint it starts at to the save.
                    if let w = m["window"] as? [String: Any], var from = (w["from"] as? NSNumber)?.doubleValue,
                       let to = (w["to"] as? NSNumber)?.doubleValue {
                        if let c = m["checkpoint"] as? [String: Any], let wall = (c["wall"] as? NSNumber)?.doubleValue { from = max(from, wall) }
                        if from > 1e12, to > from { r.duration = (to - from) / 1000 }
                    }
                }
                cache[f.path] = (date, size, r)
                found.append(r)
            }
            cache = cache.filter { seen.contains($0.key) }
            found.sort { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
            DispatchQueue.main.async { done(found) }
        }
    }

    /// The bundle's manifest.json (a zip entry), by the system's unzip.
    private static func manifest(of file: URL) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", file.path, "manifest.json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// APKs to search, oldest first: by modification time, the name breaking ties.
enum BuildOrder {
    static func apks(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                out += inside.filter { $0.pathExtension.lowercased() == "apk" }
            } else if u.pathExtension.lowercased() == "apk" {
                out.append(u)
            }
        }
        var seen = Set<String>()
        return sorted(out.filter { seen.insert($0.path).inserted })
    }

    static func sorted(_ urls: [URL]) -> [URL] {
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.sorted { mtime($0) != mtime($1) ? mtime($0) < mtime($1) : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
