import Foundation

/// One thing on a simulator's screen, from the engine's `nodes` command: a text, a field, something to tap.
struct ScreenNode {
    var left = 0, top = 0, right = 0, bottom = 0
    var field = false, click = false, password = false
    var text = "", hint = "", desc = ""
    /// The view's resource id (`com.example:id/save`), when the app gave it one.
    var resourceId = ""
    /// Where to tap when it is not the node's own centre (a label folded into the box that takes the tap).
    var tapPoint: (Int, Int)?
    /// The box that takes the tap, when it is larger than the node's own (the row or tab a label was folded into).
    var hitBox: (left: Int, top: Int, right: Int, bottom: Int)?
    /// Where a touch reaches this node: its tap box, else its own bounds.
    var frame: CGRect {
        if let h = hitBox { return CGRect(x: h.left, y: h.top, width: h.right - h.left, height: h.bottom - h.top) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    var ref = ""
    // Filled by ScreenTree.update: what this node was in the tree before, if it was there.
    var isNew = true
    var oldLabel = ""
    var oldClick = false

    var label: String { !text.isEmpty ? text : (!desc.isEmpty ? desc : hint) }
    var center: (Int, Int) { tapPoint ?? ((left + right) / 2, (top + bottom) / 2) }

    /// `e3 "Sign in" click`: the form every answer to an agent uses.
    var line: String {
        var s = ref
        if !label.isEmpty { s += " " + ScreenNode.quote(label) }
        if field, !hint.isEmpty, !text.isEmpty { s += " hint=" + ScreenNode.quote(hint) }
        let kind = field ? (password ? "pw-field" : "field") : (click ? "click" : "")
        return kind.isEmpty ? s : s + " " + kind
    }

    static func quote(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "\"\(s)\"" }
        return String(json.dropFirst().dropLast())
    }

    private static let entry = try! NSRegularExpression(pattern: #"\s*;\s*(?=\[-?\d+,-?\d+,-?\d+,-?\d+\] |\s*$)"#)
    private static let head = try! NSRegularExpression(
        pattern: #"^\[(-?\d+),(-?\d+),(-?\d+),(-?\d+)\] ?((?:(?:password-field|field|clickable|offscreen)(?: |$))*)(.*)$"#,
        options: [.dotMatchesLineSeparators])
    private static let attr = try! NSRegularExpression(
        pattern: #"(text|hint|desc|id)="(.*?)"(?= (?:text|hint|desc|id)="|\s*$)"#, options: [.dotMatchesLineSeparators])

    private static func unquote(_ v: String) -> String {
        var out = "", escaped = false
        for ch in v {
            if escaped { out.append(ch == "n" ? "\n" : ch == "r" ? "\r" : ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    /// The engine's `nodes` answer as nodes. Entries off screen are left out, and a tappable box with no text that
    /// holds exactly one text is folded into that text (a list row or tab is one entry, tapped at the box's centre).
    static func parse(_ raw: String) -> [ScreenNode] {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
        var pieces: [String] = []
        var last = flat.startIndex
        let ns = flat as NSString
        for m in entry.matches(in: flat, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: flat) else { continue }
            pieces.append(String(flat[last..<r.lowerBound]))
            last = r.upperBound
        }
        pieces.append(String(flat[last...]))

        var out: [ScreenNode] = []
        for piece in pieces {
            let p = piece as NSString
            guard let m = head.firstMatch(in: piece, range: NSRange(location: 0, length: p.length)) else { continue }
            let flags = p.substring(with: m.range(at: 5)).split(separator: " ").map(String.init)
            if flags.contains("offscreen") { continue }
            var n = ScreenNode()
            n.left = Int(p.substring(with: m.range(at: 1))) ?? 0
            n.top = Int(p.substring(with: m.range(at: 2))) ?? 0
            n.right = Int(p.substring(with: m.range(at: 3))) ?? 0
            n.bottom = Int(p.substring(with: m.range(at: 4))) ?? 0
            n.password = flags.contains("password-field")
            n.field = n.password || flags.contains("field")
            n.click = flags.contains("clickable")
            let rest = p.substring(with: m.range(at: 6)).trimmingCharacters(in: .whitespaces) as NSString
            for a in attr.matches(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                let value = unquote(rest.substring(with: a.range(at: 2)))
                switch rest.substring(with: a.range(at: 1)) {
                case "text": n.text = value
                case "hint": n.hint = value
                case "desc": n.desc = value
                case "id": n.resourceId = value
                default: break
                }
            }
            out.append(n)
        }
        var drop = Set<Int>()
        for (i, n) in out.enumerated() where (n.click || n.field) && n.label.isEmpty {
            let inside = out.indices.filter { j in
                let c = out[j]
                return !c.label.isEmpty && c.left >= n.left && c.top >= n.top && c.right <= n.right && c.bottom <= n.bottom
            }
            if inside.count == 1, !out[inside[0]].click {
                out[inside[0]].click = true
                out[inside[0]].tapPoint = ((n.left + n.right) / 2, (n.top + n.bottom) / 2)
                out[inside[0]].hitBox = (n.left, n.top, n.right, n.bottom)
                out[inside[0]].field = out[inside[0]].field || n.field
                drop.insert(i)
            }
        }
        return out.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }
}

/// The nodes a simulator last answered with and the references handed out for them: e1, e2..., never reused, so a
/// reference means the same node for as long as it is on screen. A node keeps its reference when its text is the
/// same (it may have moved: a scroll) or when other text is in the same place (a counter).
final class ScreenTree {
    private(set) var nodes: [ScreenNode] = []
    private var sequence = 0

    struct Change {
        var added: [ScreenNode] = [], removed: [ScreenNode] = [], changed: [ScreenNode] = []

        /// `~ e3 "0" -> "1"`, `- e5 "Loading"`, `+ e9 "Done" click`: at most `limit` lines.
        func lines(limit: Int = 30) -> [String] {
            var out: [String] = []
            for n in changed {
                out.append(n.oldLabel != n.label ? "~ \(n.ref) \(ScreenNode.quote(n.oldLabel)) -> \(ScreenNode.quote(n.label))" : "~ " + n.line)
            }
            // What is new before what went: when a whole screen changes, the limit cuts the end, and the screen the
            // action led to is what the next step needs.
            out += added.filter { !$0.label.isEmpty || $0.click }.map { "+ " + $0.line }
            out += removed.filter { !$0.label.isEmpty || $0.click }.map { "- " + $0.line }
            if out.count > limit { out = Array(out.prefix(limit)) + ["... \(out.count - limit) more changes: call screen"] }
            return out
        }
    }

    @discardableResult
    func update(_ fresh: [ScreenNode]) -> Change {
        let old = nodes
        var new = fresh
        var free = Array(old.indices)
        func take(_ i: Int, for n: inout ScreenNode) {
            n.ref = old[i].ref
            n.isNew = false
            n.oldLabel = old[i].label
            n.oldClick = old[i].click
            free.removeAll { $0 == i }
        }
        for k in new.indices { new[k].ref = ""; new[k].isNew = true }
        // 1. The same label and kind, nearest in order.
        for k in new.indices where !new[k].label.isEmpty {
            if let i = free.first(where: { old[$0].label == new[k].label && old[$0].field == new[k].field }) { take(i, for: &new[k]) }
        }
        // 2. Other text in the same place and kind.
        for k in new.indices where new[k].ref.isEmpty {
            if let i = free.first(where: {
                old[$0].left == new[k].left && old[$0].top == new[k].top && old[$0].field == new[k].field
                    && old[$0].click == new[k].click && (!old[$0].label.isEmpty || new[k].label.isEmpty)
            }) { take(i, for: &new[k]) }
        }
        // 3. Unlabelled things to tap: the same box.
        for k in new.indices where new[k].ref.isEmpty && new[k].label.isEmpty {
            if let i = free.first(where: {
                old[$0].label.isEmpty && old[$0].left == new[k].left && old[$0].top == new[k].top
                    && old[$0].right == new[k].right && old[$0].bottom == new[k].bottom
            }) { take(i, for: &new[k]) }
        }
        for k in new.indices where new[k].ref.isEmpty {
            sequence += 1
            new[k].ref = "e\(sequence)"
        }
        nodes = new
        return Change(added: new.filter(\.isNew), removed: free.map { old[$0] },
                      changed: new.filter { !$0.isNew && ($0.oldLabel != $0.label || $0.oldClick != $0.click) })
    }

    func node(ref: String) -> ScreenNode? { nodes.first { $0.ref == ref } }
}
