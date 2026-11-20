import Foundation

/// One HTTP exchange the app made, as the engine's network inspector reports it (`netwatch`): read from the app's own
/// connection as it passes, so watching changes nothing the app sees.
struct NetEvent {
    let id: Int
    let start: Date
    let ms: Int
    let method: String
    let url: String
    let status: Int
    let reqBytes: Int
    let respBytes: Int
    let type: String?
    let http: String?
    let error: String?
    let mocked: Bool

    var end: Date { start.addingTimeInterval(Double(ms) / 1000) }
    var failed: Bool { status == 0 || status >= 400 || error != nil }

    /// `api.example.com/v2/trips` from `https://api.example.com/v2/trips`.
    var shortURL: String {
        var s = url
        for p in ["https://", "http://", "wss://", "ws://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s
    }

    init?(json: [String: Any], received: Date) {
        guard let id = json["id"] as? Int, let method = json["method"] as? String, let url = json["url"] as? String else { return nil }
        self.id = id
        self.method = method
        self.url = url
        status = json["status"] as? Int ?? 0
        ms = max(0, json["ms"] as? Int ?? 0)
        reqBytes = json["reqBytes"] as? Int ?? 0
        respBytes = json["respBytes"] as? Int ?? -1
        type = json["type"] as? String
        http = json["http"] as? String
        error = json["error"] as? String
        mocked = json["rule"] != nil || json["patched"] as? Bool == true
        // `t`: when the request began, in epoch milliseconds. Without one, it ended as it arrived.
        if let t = json["t"] as? Double, t > 0 { start = Date(timeIntervalSince1970: t / 1000) }
        else { start = received.addingTimeInterval(-Double(ms) / 1000) }
    }
}

/// What happened in one simulator lately, on one clock: touches, frames drawn, requests and log lines by level. The
/// timeline draws it and the network pane lists its requests. Kept for the last ten minutes.
final class Activity {
    struct LogMark { let time: Date; let level: Character }

    private let lock = NSLock()
    private var _touches: [Date] = []
    private var _frames: [Date] = []
    private var _requests: [NetEvent] = []
    private var _logs: [LogMark] = []
    private static let keep: TimeInterval = 600
    /// Called on the main thread after new requests arrive.
    var onRequests: (() -> Void)?

    var touches: [Date] { lock.withLock { _touches } }
    var frames: [Date] { lock.withLock { _frames } }
    var requests: [NetEvent] { lock.withLock { _requests } }
    var logs: [LogMark] { lock.withLock { _logs } }

    func touched() { lock.withLock { _touches.append(Date()); trim(&_touches) } }

    func frameShown() {
        lock.withLock {
            _frames.append(Date())
            if _frames.count > 80_000 { _frames.removeFirst(_frames.count - 80_000) }
        }
    }

    /// Log output as it is written: each line that starts as android.util.Log's do (`E/Tag: ...`) is marked by level.
    func logged(_ data: Data) {
        let now = Date()
        var marks: [LogMark] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: true) where line.count > 2 {
            let first = line[line.startIndex], second = line[line.startIndex + 1]
            if second == UInt8(ascii: "/"), "VDIWEF".utf8.contains(first) {
                marks.append(LogMark(time: now, level: Character(UnicodeScalar(first))))
            }
        }
        guard !marks.isEmpty else { return }
        lock.withLock { _logs += marks; if _logs.count > 20_000 { _logs.removeFirst(_logs.count - 20_000) } }
    }

    func add(_ e: NetEvent) {
        lock.withLock {
            _requests.append(e)
            if _requests.count > 2000 { _requests.removeFirst(_requests.count - 2000) }
        }
    }

    private func trim(_ list: inout [Date]) {
        let cut = Date().addingTimeInterval(-Activity.keep)
        if let first = list.first, first < cut { list.removeAll { $0 < cut } }
    }
}

/// The engine's `netwatch` stream: one JSON line per finished exchange, the recent ones first.
final class NetFeed {
    private let socket: LoopbackSocket

    init?(port: Int, token: String?) {
        guard let s = LoopbackSocket(port: port) else { return nil }
        socket = s
        if let token { guard s.write(line: "auth \(token)"), s.readLine() == "ok" else { s.close(); return nil } }
        guard s.write(line: "netwatch"), s.readLine() == "ok netwatch" else { s.close(); return nil }
    }

    func start(into activity: Activity) {
        let t = Thread { [socket] in
            let pending = NSLock()
            var scheduled = false
            while let line = socket.readLine() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let e = NetEvent(json: json, received: Date()) else { continue }
                activity.add(e)
                // The window hears at most five times a second, however fast a backlog streams in.
                let tell = pending.withLock { () -> Bool in if scheduled { return false }; scheduled = true; return true }
                if tell {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        pending.withLock { scheduled = false }
                        activity.onRequests?()
                    }
                }
            }
        }
        t.name = "greenroom-netwatch"
        t.qualityOfService = .utility
        t.start()
    }

    func close() { socket.close() }
}
