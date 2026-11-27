import Darwin
import Foundation

/// A server the app keeps failing to connect to, and the likeliest reason, in this Mac's terms. The app itself only
/// says "can't reach the server"; the stage says which address it tried and why that address can't work from here
/// (nothing listening on this Mac, a home network this Mac isn't on, Tailscale off), from the engine's failed
/// CONNECT and DNS rows.
struct Unreachable: Equatable {
    /// `127.0.0.1:8971`, or a host name when its lookup failed.
    let address: String
    let failures: Int
    let reason: String

    /// Failed connects to one address heard of this recently, and at least this many, with nothing to that host succeeding since.
    static let window: TimeInterval = 60
    static let minFailures = 2

    /// The addresses `requests` (oldest first) keep failing on, the most failures first.
    static func find(in requests: [NetEvent], now: Date = Date(), mac: [MacAddress] = MacAddress.current()) -> [Unreachable] {
        let cut = now.addingTimeInterval(-window)
        var failed: [String: (host: String, port: Int?, count: Int, first: Date, dns: Bool)] = [:]
        var lastSuccess: [String: Date] = [:]
        for e in requests where e.received >= cut {
            if e.failed && (e.method == "CONNECT" || e.method == "DNS") {
                let (host, port) = split(e.url, dns: e.method == "DNS")
                let key = e.method == "DNS" ? host : e.url
                var f = failed[key] ?? (host, port, 0, e.received, e.method == "DNS")
                f.count += 1
                failed[key] = f
            } else if !e.failed {
                let host = (e.url.contains("://") ? URLComponents(string: e.url)?.host : nil) ?? split(e.url, dns: e.method == "DNS").host
                lastSuccess[host.lowercased()] = max(lastSuccess[host.lowercased()] ?? .distantPast, e.received)
            }
        }
        return failed
            .filter { $0.value.count >= minFailures && (lastSuccess[$0.value.host.lowercased()] ?? .distantPast) < $0.value.first }
            .map { key, f in Unreachable(address: key, failures: f.count, reason: reason(host: f.host, port: f.port, dns: f.dns, mac: mac)) }
            .sorted { ($0.failures, $1.address) > ($1.failures, $0.address) }
    }

    /// `host:port` (with `[v6]:port`) apart; a DNS row is a bare name.
    static func split(_ s: String, dns: Bool) -> (host: String, port: Int?) {
        if dns { return (s, nil) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        guard let colon = s.lastIndex(of: ":"), s.firstIndex(of: ":") == colon, let port = Int(s[s.index(after: colon)...]) else { return (s, nil) }
        return (String(s[..<colon]), port)
    }

    /// Why `host` can't be reached from this Mac, in a few words.
    static func reason(host: String, port: Int?, dns: Bool, mac: [MacAddress]) -> String {
        let h = host.lowercased()
        let onTailnet = mac.contains { tailnet($0.address) }
        if h.hasSuffix(".ts.net") || ipv4(h).map(tailnet) == true {
            if !onTailnet { return "Tailscale is off on this Mac" }
            return dns ? "this Mac's Tailscale doesn't know that name" : "Tailscale is on, but that device doesn't answer"
        }
        if dns { return "that name doesn't resolve on this Mac" }
        if h == "localhost" || h == "::1" || h.hasPrefix("127.") {
            return "nothing on this Mac is listening on port \(port.map(String.init) ?? "that port")"
        }
        if let ip = ipv4(h), isPrivate(ip) {
            if mac.contains(where: { $0.mask != 0 && ($0.address & $0.mask) == (ip & $0.mask) }) {
                return "nothing answers there on this Mac's network"
            }
            let lans = mac.filter { isPrivate($0.address) && !tailnet($0.address) }.map { subnetLabel($0) }
            return lans.isEmpty ? "that's a local network address, and this Mac isn't on one"
                                : "it's on a different local network than this Mac (\(lans.joined(separator: ", ")))"
        }
        return "no answer from that server"
    }

    static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    /// 100.64.0.0/10, where Tailscale gives out its addresses.
    static func tailnet(_ ip: UInt32) -> Bool { ip & 0xFFC0_0000 == 0x6440_0000 }

    static func isPrivate(_ ip: UInt32) -> Bool {
        ip & 0xFF00_0000 == 0x0A00_0000 || ip & 0xFFF0_0000 == 0xAC10_0000 || ip & 0xFFFF_0000 == 0xC0A8_0000
    }

    /// `192.168.1.x` for a /24 (what people recognise), else `10.0.0.0/16`.
    static func subnetLabel(_ a: MacAddress) -> String {
        let net = a.address & a.mask
        let o = [24, 16, 8, 0].map { (net >> UInt32($0)) & 0xFF }
        if a.mask == 0xFFFF_FF00 { return "\(o[0]).\(o[1]).\(o[2]).x" }
        return "\(o[0]).\(o[1]).\(o[2]).\(o[3])/\(a.mask.nonzeroBitCount)"
    }
}

/// One IPv4 address of this Mac's, on an interface that is up (loopback left out).
struct MacAddress: Equatable {
    let address: UInt32
    let mask: UInt32

    static func current() -> [MacAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [MacAddress] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            func v4(_ s: UnsafeMutablePointer<sockaddr>?) -> UInt32 {
                guard let s else { return 0 }
                return s.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            out.append(MacAddress(address: v4(a), mask: v4(i.ifa_netmask)))
        }
        return out
    }
}
