import CoreServices
import Foundation

/// Notices a changed `.apk` under a folder (a Gradle outputs folder) through FSEvents: no polling. A change is
/// reported once the file has stopped changing (a build writes it in pieces), a second after the last event.
final class BuildWatcher {
    /// The folders watched: one for a build folder, a worktree each for Sessions (one stream covers them all).
    let folders: [URL]
    var folder: URL { folders[0] }
    /// Only this file name counts; nil for any `.apk`.
    let name: String?
    /// A finished build, on the main thread.
    var onBuild: ((URL) -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "greenroom-buildwatch", qos: .utility)
    private var pending: [String: DispatchWorkItem] = [:]
    private static let debounce: TimeInterval = 1.0
    private static let sizeCheck: TimeInterval = 0.5

    convenience init(folder: URL, name: String?) { self.init(folders: [folder], name: name) }

    init(folders: [URL], name: String?) {
        self.folders = folders
        self.name = name
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<BuildWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // Only a file made, written or moved into place is a build: a change of its attributes alone (the system
            // marks a file an engine has just read) is not.
            let content = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed)
            me.changed(list.prefix(count).enumerated().compactMap { i, path in flags[i] & content != 0 ? path : nil })
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, folders.map { $0.resolvingSymlinksInPath().path } as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false }
        stream = s
        return true
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        queue.sync { for item in pending.values { item.cancel() }; pending.removeAll() }
    }

    /// On the event queue.
    private func changed(_ paths: [String]) {
        for path in paths where path.hasSuffix(".apk") {
            if let name, (path as NSString).lastPathComponent != name { continue }
            pending[path]?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.settle(path, lastSize: -1, tries: 0) }
            pending[path] = item
            queue.asyncAfter(deadline: .now() + Self.debounce, execute: item)
        }
    }

    /// Waits for the file to stop growing, then reports it.
    private func settle(_ path: String, lastSize: Int, tries: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) else { pending[path] = nil; return }   // gone
        if size > 0, size == lastSize {
            pending[path] = nil
            DispatchQueue.main.async { [weak self] in self?.onBuild?(URL(fileURLWithPath: path)) }
        } else if tries < 120 {
            let item = DispatchWorkItem { [weak self] in self?.settle(path, lastSize: size, tries: tries + 1) }
            pending[path] = item
            queue.asyncAfter(deadline: .now() + Self.sizeCheck, execute: item)
        } else {
            pending[path] = nil
        }
    }
}
