import AppKit

/// Merging a session's pull request from Greenroom (docs/AGENT-FIRST-SPEC.md, the owner's decision 6): by the person
/// only, beside Approve. It is done by `gh`, as the account the person signed it in with, for the commit the session
/// is at and no other (`--match-head-commit`), with the method the repository allows. No tool of the agent interface
/// reaches this file: an agent cannot merge.
enum Merger {
    enum Method: String, CaseIterable {
        case squash, merge, rebase

        var title: String {
            switch self {
            case .squash: return "Squash and merge"
            case .merge: return "Create a merge commit"
            case .rebase: return "Rebase and merge"
            }
        }
        var flag: String { "--" + rawValue }
    }

    /// A pull request as GitHub has it now.
    struct Info: Equatable {
        var number: Int
        var title: String
        var url: URL?
        /// OPEN, MERGED or CLOSED.
        var state: String
        var isDraft = false
        /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub has not worked it out yet).
        var mergeable = "UNKNOWN"
        /// The commit its branch is at on GitHub.
        var head: String
        var base: String
        /// Its checks: how many passed, failed, and have not finished.
        var passed = 0, failed = 0, pending = 0
        /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil when the repository asks for none.
        var review: String?
        /// The ways the repository lets a pull request be merged, the one it prefers first.
        var methods: [Method] = [.squash, .merge, .rebase]

        /// "3 checks passed", "1 of 4 checks failed", "2 checks still running".
        var checksLine: String {
            let n = passed + failed + pending
            if n == 0 { return "No checks" }
            if failed > 0 { return "\(failed) of \(n) check\(n == 1 ? "" : "s") failed" }
            if pending > 0 { return "\(pending) of \(n) check\(n == 1 ? "" : "s") still running" }
            return "\(n) check\(n == 1 ? "" : "s") passed"
        }
    }

    struct Failure: Error, Equatable { var message: String }

    /// The pull request of a session's branch, read from GitHub. Nil: the branch has none.
    static func read(_ s: Session) async -> Result<Info?, Failure> {
        let dir = s.worktree
        let which = s.githubPR.map { String($0.number) } ?? s.branch
        guard let which else { return .success(nil) }
        let r = await GH.run(["pr", "view", which, "--json", "number,title,url,state,isDraft,mergeable,headRefOid,baseRefName,reviewDecision,statusCheckRollup"], in: dir, timeout: 30)
        if r.status == 127 { return .failure(Failure(message: r.err)) }
        guard r.status == 0 else {
            let why = GH.why(r)
            if why.localizedCaseInsensitiveContains("no pull requests found") { return .success(nil) }
            return .failure(Failure(message: why))
        }
        guard var info = parse(r.out) else { return .failure(Failure(message: "gh's answer about the pull request could not be read")) }
        let repo = await GH.run(["repo", "view", "--json", "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,viewerDefaultMergeMethod"], in: dir, timeout: 30)
        if repo.status == 0 { info.methods = methods(repo.out) }
        return .success(info)
    }

    static func parse(_ json: String) -> Info? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let number = o["number"] as? Int, let head = o["headRefOid"] as? String else { return nil }
        var info = Info(number: number, title: o["title"] as? String ?? "", url: (o["url"] as? String).flatMap { URL(string: $0) },
                        state: o["state"] as? String ?? "OPEN", head: head, base: o["baseRefName"] as? String ?? "")
        info.isDraft = o["isDraft"] as? Bool ?? false
        info.mergeable = o["mergeable"] as? String ?? "UNKNOWN"
        info.review = (o["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for c in o["statusCheckRollup"] as? [[String: Any]] ?? [] {
            // A check run says how it ended once it is completed; a commit status has one state.
            let done = (c["status"] as? String).map { $0 == "COMPLETED" } ?? true
            let end = ((c["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c["state"] as? String ?? "").uppercased()
            if !done || ["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", ""].contains(end) { info.pending += 1 }
            else if ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(end) { info.passed += 1 }
            else { info.failed += 1 }
        }
        return info
    }

    static func methods(_ json: String) -> [Method] {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return Method.allCases }
        var out: [Method] = []
        if o["squashMergeAllowed"] as? Bool ?? true { out.append(.squash) }
        if o["mergeCommitAllowed"] as? Bool ?? true { out.append(.merge) }
        if o["rebaseMergeAllowed"] as? Bool ?? true { out.append(.rebase) }
        if let preferred = Method(rawValue: (o["viewerDefaultMergeMethod"] as? String ?? "").lowercased()), let i = out.firstIndex(of: preferred) {
            out.insert(out.remove(at: i), at: 0)
        }
        return out.isEmpty ? Method.allCases : out
    }

    /// Why it cannot be merged from here now (nil: it can).
    static func block(_ info: Info, session s: Session) -> String? {
        if info.state == "MERGED" { return "Merged" }
        if info.state != "OPEN" { return "The pull request is closed" }
        if info.isDraft { return "It is a draft: mark it ready on GitHub first" }
        if info.mergeable == "CONFLICTING" { return "It has conflicts with \(info.base)" }
        if info.head != s.head {
            return "The pull request is at \(info.head.prefix(7)) and this session at \(s.shortHead): push first, so what is merged is what you looked at here"
        }
        return nil
    }

    /// What the person is told before they say yes: none of it stops the merge (GitHub's own rules may).
    static func warnings(_ info: Info, session s: Session, approved: Bool, criteria: (failed: Int, unchecked: Int)) -> [String] {
        var out: [String] = []
        if info.failed > 0 { out.append(info.checksLine + " on GitHub.") }
        else if info.pending > 0 { out.append(info.checksLine + " on GitHub.") }
        if info.review == "CHANGES_REQUESTED" { out.append("A reviewer on GitHub asked for changes.") }
        if info.review == "REVIEW_REQUIRED" { out.append("GitHub still wants a review.") }
        if !approved { out.append("You have not approved this commit in Greenroom.") }
        if criteria.failed > 0 { out.append("\(criteria.failed) of the spec's criteria failed.") }
        else if criteria.unchecked > 0 { out.append("\(criteria.unchecked) of the spec's criteria \(criteria.unchecked == 1 ? "was" : "were") not checked.") }
        if s.dirty { out.append("The worktree has uncommitted changes, which are not part of the pull request.") }
        return out
    }

    /// Merges it. Nil: done; else why not, in gh's own words.
    static func merge(_ info: Info, method: Method, in dir: URL) async -> String? {
        let r = await GH.run(["pr", "merge", String(info.number), method.flag, "--match-head-commit", info.head], in: dir, timeout: 120)
        return r.status == 0 ? nil : GH.why(r)
    }

    /// For a check: answers the question instead of the person (nil: ask them).
    static var answerForCheck: ((_ text: String, _ methods: [Method]) -> Method?)?

    /// Asks the person, with what they should know, and the method to use. Nil: they said no.
    static func ask(_ info: Info, warnings: [String], in window: NSWindow?, then: @escaping (Method?) -> Void) {
        let body = (["\u{201C}\(info.title)\u{201D} into \(info.base), as your GitHub account. " + (info.failed + info.pending == 0 ? info.checksLine + " on GitHub." : "")]
            + warnings).filter { !$0.isEmpty }.joined(separator: "\n")
        if let answer = answerForCheck { then(answer(body, info.methods)); return }
        let alert = NSAlert()
        alert.messageText = "Merge pull request #\(info.number)?"
        alert.informativeText = body
        alert.alertStyle = warnings.isEmpty ? .informational : .warning
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        for m in info.methods { menu.addItem(withTitle: m.title) }
        alert.accessoryView = menu
        alert.addButton(withTitle: warnings.isEmpty ? "Merge" : "Merge Anyway")
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { r in
            then(r == .alertFirstButtonReturn ? info.methods[max(0, menu.indexOfSelectedItem)] : nil)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }
}
