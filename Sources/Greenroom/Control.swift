import Foundation

/// A blocking TCP socket to the engine on this Mac's loopback interface.
final class LoopbackSocket {
    private(set) var fd: Int32 = -1

    init?(port: Int) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ok != 0 { Darwin.close(fd); fd = -1; return nil }
    }

    deinit { close() }

    func close() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }

    @discardableResult
    func write(_ data: [UInt8]) -> Bool {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, data.count - sent) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    func write(line: String) -> Bool { write(Array((line + "\n").utf8)) }

    /// Exactly `count` bytes, or nil once the other side has gone.
    func read(count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return buf
    }

    /// One line without its newline. Reads a byte at a time: used for the short answers before a stream starts.
    func readLine() -> String? {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &b, 1)
            if n <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if b == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(b)
        }
    }
}

/// The engine's control channel: one line out, one line back, in order. Commands are written as they are sent
/// (touch moves must not wait for earlier answers) and a reader thread hands each answer to its sender.
final class ControlChannel {
    private let socket: LoopbackSocket
    private let lock = NSLock()
    private var waiting: [((String) -> Void)?] = []
    private var reader: Thread?

    /// `token`: what an engine started with `--control-token-file` wants first on every connection.
    init?(port: Int, token: String? = nil) {
        guard let s = LoopbackSocket(port: port) else { return nil }
        socket = s
        if let token {
            guard s.write(line: "auth \(token)"), s.readLine() == "ok" else { s.close(); return nil }
        }
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "greenroom-control"
        t.qualityOfService = .userInteractive
        t.start()
        reader = t
    }

    /// Sends a command. `reply`, if given, is called on the main thread with the engine's one-line answer.
    func send(_ command: String, reply: ((String) -> Void)? = nil) {
        lock.lock()
        waiting.append(reply)
        let ok = socket.write(line: command)
        if !ok { waiting.removeLast() }
        lock.unlock()
        if !ok, let reply { DispatchQueue.main.async { reply("error: the simulator has gone") } }
    }

    func close() { socket.close() }

    private func readLoop() {
        var pending: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(socket.fd, $0.baseAddress!, 65536) }
            if n <= 0 { break }
            pending.append(contentsOf: chunk[0..<n])
            while let nl = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[0..<nl], as: UTF8.self)
                pending.removeSubrange(0...nl)
                lock.lock()
                let handler = waiting.isEmpty ? nil : waiting.removeFirst()
                lock.unlock()
                if let handler { DispatchQueue.main.async { handler(line) } }
            }
        }
        lock.lock()
        let left = waiting
        waiting.removeAll()
        lock.unlock()
        for h in left { if let h { DispatchQueue.main.async { h("error: the simulator has gone") } } }
    }
}

/// The engine's screen as H.264: `stream QUALITY h264 KBPS` on a control connection of its own, after which the
/// engine sends frames (FrameStream's wire format, big-endian): int32 length of the rest, int32 width, int32 height,
/// int64 present time in epoch microseconds, int32 encode microseconds, a keyframe byte, the access unit in Annex B.
final class FrameChannel {
    struct Frame {
        let width: Int, height: Int
        let presentMicros: Int64
        let keyframe: Bool
        let unit: [UInt8]   // Annex B
    }

    private let socket: LoopbackSocket
    var onFrame: ((Frame) -> Void)?   // called on the reader thread
    var onEnd: (() -> Void)?

    init?(port: Int, kbps: Int, token: String? = nil) {
        guard let s = LoopbackSocket(port: port) else { return nil }
        socket = s
        if let token {
            guard s.write(line: "auth \(token)"), s.readLine() == "ok" else { s.close(); return nil }
        }
        guard s.write(line: "stream 80 h264 \(kbps)"), let answer = s.readLine(), answer == "ok stream h264" else {
            s.close(); return nil
        }
    }

    func start() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "greenroom-frames"
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Asks for a keyframe (the decoder lost its place).
    func requestKeyframe() { _ = socket.write(line: "key") }

    func close() { socket.close() }

    private func readLoop() {
        func int32(_ b: [UInt8], _ at: Int) -> Int { Int(Int32(bitPattern: UInt32(b[at]) << 24 | UInt32(b[at+1]) << 16 | UInt32(b[at+2]) << 8 | UInt32(b[at+3]))) }
        while let head = socket.read(count: 4) {
            let length = int32(head, 0)
            guard length >= 21, length < 64 << 20, let body = socket.read(count: length) else { break }
            var micros: Int64 = 0
            for i in 8..<16 { micros = micros << 8 | Int64(body[i]) }
            // A frame scaled for a small viewer carries the device's size in the upper 16 bits; none is asked for here.
            let frame = Frame(width: int32(body, 0) & 0xffff, height: int32(body, 4) & 0xffff, presentMicros: micros,
                              keyframe: body[20] == 1, unit: Array(body[21...]))
            onFrame?(frame)
        }
        onEnd?()
    }
}
