import Foundation

/// `Greenroom --unreachable-check`: the stage's "Can't reach" notice (Unreachable) from made-up network rows and a
/// made-up Mac: which addresses it names, and the reason it gives for each. No window, no engine.
enum UnreachableCheck {
    static func run() -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] unreachable: \(good ? "ok  " : "FAIL") \(what)") }
        let now = Date()
        var id = 0
        func row(_ method: String, _ url: String, _ status: Int, ago: TimeInterval) -> NetEvent {
            id += 1
            return NetEvent(json: ["id": id, "method": method, "url": url, "status": status, "t": (now.timeIntervalSince1970 - ago) * 1000],
                            received: now.addingTimeInterval(-ago))!
        }
        func mac(_ s: String, _ mask: String) -> MacAddress { MacAddress(address: Unreachable.ipv4(s)!, mask: Unreachable.ipv4(mask)!) }
        let away = [mac("192.168.1.231", "255.255.255.0"), mac("100.120.179.25", "255.255.255.255")]
        let home = [mac("192.168.68.40", "255.255.252.0")]

        // The case that asked for it: a dev server on this Mac that isn't running, and the home network's address.
        let found = Unreachable.find(in: [
            row("CONNECT", "127.0.0.1:8971", 0, ago: 30), row("CONNECT", "127.0.0.1:8971", 0, ago: 20), row("CONNECT", "127.0.0.1:8971", 0, ago: 10),
            row("CONNECT", "192.168.68.65:8971", 0, ago: 25), row("CONNECT", "192.168.68.65:8971", 0, ago: 5),
        ], now: now, mac: away)
        expect(found.map(\.address) == ["127.0.0.1:8971", "192.168.68.65:8971"], "both addresses, the most failures first: \(found.map(\.address))")
        expect(found.first?.reason == "nothing on this Mac is listening on port 8971", "loopback: \(found.first?.reason ?? "-")")
        expect(found.last?.reason == "it's on a different local network than this Mac (192.168.1.x)", "another LAN: \(found.last?.reason ?? "-")")

        expect(Unreachable.find(in: [row("CONNECT", "127.0.0.1:8971", 0, ago: 5)], now: now, mac: away).isEmpty, "one failure says nothing yet")
        // A connect to a LAN host that isn't there times out after ~75 s: its row starts then, and arrives now.
        let late = [NetEvent(json: ["id": 90, "method": "CONNECT", "url": "192.168.68.65:8971", "status": 0, "t": (now.timeIntervalSince1970 - 80) * 1000], received: now)!,
                    NetEvent(json: ["id": 91, "method": "CONNECT", "url": "192.168.68.65:8971", "status": 0, "t": (now.timeIntervalSince1970 - 79) * 1000], received: now)!]
        expect(Unreachable.find(in: late, now: now, mac: away).count == 1, "connects that took over a minute to fail still count")
        expect(Unreachable.find(in: [row("CONNECT", "10.0.0.2:80", 0, ago: 90), row("CONNECT", "10.0.0.2:80", 0, ago: 80)], now: now, mac: away).isEmpty,
               "failures older than a minute say nothing")
        expect(Unreachable.find(in: [row("CONNECT", "api.example.com:443", 0, ago: 30), row("CONNECT", "api.example.com:443", 0, ago: 20),
                                     row("GET", "https://api.example.com/v1/x", 200, ago: 10)], now: now, mac: away).isEmpty,
               "a later success to the host clears it")
        expect(!Unreachable.find(in: [row("GET", "https://api.example.com/v1/x", 200, ago: 40), row("CONNECT", "api.example.com:443", 0, ago: 30),
                                      row("CONNECT", "api.example.com:443", 0, ago: 20)], now: now, mac: away).isEmpty,
               "an earlier success doesn't")
        expect(Unreachable.find(in: [row("GET", "https://api.example.com/v1/x", 500, ago: 30), row("GET", "https://api.example.com/v1/x", 500, ago: 20)],
                                now: now, mac: away).isEmpty, "a server that answers with an error isn't unreachable")

        func reason(_ host: String, _ port: Int? = 443, dns: Bool = false, _ m: [MacAddress]) -> String { Unreachable.reason(host: host, port: port, dns: dns, mac: m) }
        expect(reason("100.99.163.71", 8971, home) == "Tailscale is off on this Mac", "tailnet address, Tailscale off")
        expect(reason("100.99.163.71", 8971, away) == "Tailscale is on, but that device doesn't answer", "tailnet address, Tailscale on")
        expect(reason("frigate.tail4c441a.ts.net", nil, dns: true, home) == "Tailscale is off on this Mac", "tailnet name, Tailscale off")
        expect(reason("frigate.tail4c441a.ts.net", nil, dns: true, away) == "this Mac's Tailscale doesn't know that name", "tailnet name, Tailscale on")
        expect(reason("api.example.test", nil, dns: true, away) == "that name doesn't resolve on this Mac", "a name that doesn't resolve")
        expect(reason("localhost", 3000, away) == "nothing on this Mac is listening on port 3000", "localhost")
        expect(reason("::1", 3000, away) == "nothing on this Mac is listening on port 3000", "::1")
        expect(reason("192.168.68.65", 8971, home) == "nothing answers there on this Mac's network", "this Mac's own LAN (a /22)")
        expect(reason("192.168.68.65", 8971, [mac("100.120.179.25", "255.255.255.255")]) == "that's a local network address, and this Mac isn't on one", "no LAN at all")
        expect(reason("93.184.216.34", 443, away) == "no answer from that server", "a public address")

        expect(Unreachable.split("[::1]:8080", dns: false) == ("::1", 8080), "an IPv6 address and port")
        expect(Unreachable.split("example.com:443", dns: false) == ("example.com", 443), "a name and port")
        expect(!MacAddress.current().isEmpty, "this Mac's own addresses are read")
        print(ok ? "[greenroom] unreachable: all ok" : "[greenroom] unreachable: FAILED")
        exit(ok ? 0 : 1)
    }
}
