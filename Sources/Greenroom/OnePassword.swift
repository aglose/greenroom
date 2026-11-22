import Foundation

/// 1Password as a source of variables: a variable whose value is a secret reference (`op://Private/MyApp/password`)
/// is read from 1Password by its CLI, `op read`, when a script starts (by hand, before a signed-in screen map walk, or
/// when an agent runs one the person allowed), and never stored by Greenroom.
///
/// - The CLI reaches the 1Password app through its desktop integration (1Password > Settings > Developer > Integrate
///   with 1Password CLI): 1Password asks the person to approve (Touch ID) and keeps that for a while. No token, no
///   password and no account details are kept here.
/// - What is read lives only in the environment of the script that asked for it, and is masked as `••••` in what
///   Greenroom shows, keeps and hands an agent, as any secret variable is. An agent never sees it.
/// - Build recipes do not get these: a build runs on its own, with nobody there to approve.
enum OnePassword {
    static let prefix = "op://"

    static func isReference(_ value: String) -> Bool { value.hasPrefix(prefix) }

    enum Failure: LocalizedError {
        case noCLI, failed(String), timedOut
        var errorDescription: String? {
            switch self {
            case .noCLI: return "The 1Password CLI (op) is not installed. Install it (brew install 1password-cli) and turn on 1Password > Settings > Developer > Integrate with 1Password CLI."
            case .failed(let why): return why
            case .timedOut: return "1Password did not answer in time (was the approval left waiting?)."
            }
        }
    }

    /// For checks: a stand-in for `op`.
    static var cliOverride: String?

    /// `op`: on the login shell's PATH, or where Homebrew and 1Password's installer put it.
    static func cli(path: String?) -> String? {
        if let o = cliOverride { return o }
        let dirs = (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { ($0 as NSString).appendingPathComponent("op") }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reads one secret reference. Blocks (1Password may be waiting for the person's approval): never on the main thread.
    static func read(_ reference: String, env: [String: String], timeout: TimeInterval = 120) -> Result<String, Failure> {
        precondition(!Thread.isMainThread)
        guard let op = cli(path: env["PATH"]) else { return .failure(.noCLI) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: op)
        p.arguments = ["read", "--no-newline", reference]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isErr) in [(out, false), (err, true)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if isErr { errData = d } else { outData = d }
                group.leave()
            }
        }
        do { try p.run() } catch { return .failure(.failed("Could not start op: \(error.localizedDescription)")) }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 3)
            return .failure(.timedOut)
        }
        group.wait()
        guard p.terminationStatus == 0 else {
            // op's own message ("[ERROR] 2026/11/21 ... could not read secret ...: item not found"), without its prefix.
            var why = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = why.range(of: #"^\[ERROR\] [0-9/]+ [0-9:]+ "#, options: .regularExpression) { why.removeSubrange(r) }
            return .failure(.failed(why.isEmpty ? "op exited with status \(p.terminationStatus)" : why))
        }
        return .success(String(decoding: outData, as: UTF8.self))
    }
}
