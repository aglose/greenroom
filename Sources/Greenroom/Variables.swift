import Foundation
import Security

/// Variables the person keeps for sign-ins and test set-up (LOGIN_EMAIL, LOGIN_PASSWORD, API_BASE...): passed as
/// environment variables to the scripts they run (Scripts), to build recipes, and to the scripts an agent may run.
///
/// - Kept in the login Keychain, one generic-password item per variable (service `<bundle id>.variables`), never in a
///   file of Greenroom's. Listing reads names only; values are read when a script or recipe starts.
/// - A secret one is shown as dots in Settings, and its value is replaced by `••••` in every script and build log
///   Greenroom shows or keeps, and in what an agent gets back. An agent never reads a value.
/// - Names are environment names, and never one Greenroom or the engine sets (GREENROOM_*, APKSIM_*, PATH, HOME...).
/// - A value that is a 1Password secret reference (`op://Vault/Item/field`) is kept as that reference and read from
///   1Password only when a script starts (OnePassword); it is always secret, and build recipes do not get it.
/// - Checks (`--*-check`) keep them in memory, never in the person's Keychain.
final class Variables {
    struct Variable: Equatable, Identifiable {
        var name: String
        var value: String
        var secret: Bool
        var id: String { name }
        /// The value names a 1Password item's field rather than being the value.
        var fromOnePassword: Bool { OnePassword.isReference(value) }
    }

    enum Failure: LocalizedError {
        case badName(String)
        case keychain(OSStatus)
        case onePassword(String, OnePassword.Failure)
        var errorDescription: String? {
            switch self {
            case .badName(let n): return "\u{201C}\(n)\u{201D} can't be a variable's name: use letters, digits and _, not starting with a digit, and not one Greenroom sets (GREENROOM_…, APKSIM_…, PATH, HOME…)."
            case .keychain(let s): return "The Keychain refused it: " + ((SecCopyErrorMessageString(s, nil) as String?) ?? "error \(s)")
            case .onePassword(let n, let f): return "\(n) could not be read from 1Password: " + (f.errorDescription ?? "")
            }
        }
    }

    static let shared = Variables(memory: CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-check") })

    /// Set by checks: nothing reaches the Keychain.
    private let memory: Bool
    private var _stored: [String: Variable] = [:]
    private let lock = NSLock()
    private var stored: [String: Variable] {
        get { lock.lock(); defer { lock.unlock() }; return _stored }
        set { lock.lock(); _stored = newValue; lock.unlock() }
    }
    let service: String

    init(memory: Bool, service: String = (Bundle.main.bundleIdentifier ?? "Greenroom") + ".variables") {
        self.memory = memory
        self.service = service
    }

    private static let reserved: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT"]

    static func isValid(_ name: String) -> Bool {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else { return false }
        let up = name.uppercased()
        return !reserved.contains(up) && !up.hasPrefix("GREENROOM_") && !up.hasPrefix("APKSIM_") && !up.hasPrefix("DYLD_")
    }

    // MARK: Reading

    /// Every variable's name and whether it is secret, sorted by name. Reads no value (so the Keychain asks nothing).
    /// `onePassword`: its value is a 1Password reference (kept as the item's comment, so telling needs no value read).
    func names() -> [(name: String, secret: Bool, onePassword: Bool)] {
        if memory { return stored.values.sorted { $0.name < $1.name }.map { ($0.name, $0.secret, $0.fromOnePassword) } }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item -> (String, Bool, Bool)? in
            guard let name = item[kSecAttrAccount as String] as? String else { return nil }
            let kind = item[kSecAttrComment as String] as? String
            return (name, kind != "plain", kind == "1password")
        }.sorted { $0.0 < $1.0 }
    }

    /// Every variable with its value. The Keychain may ask the person first (a new build of the app, say).
    func all() -> [Variable] {
        names().compactMap { n in value(of: n.name).map { Variable(name: n.name, value: $0, secret: n.secret) } }
    }

    func value(of name: String) -> String? {
        if memory { return stored[name]?.value }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The variables as an environment: what scripts, recipes and agent-run scripts get.
    func environment() -> [String: String] {
        var env: [String: String] = [:]
        for v in all() { env[v.name] = v.value }
        return env
    }

    // MARK: Writing

    func set(_ v: Variable) throws {
        guard Self.isValid(v.name) else { throw Failure.badName(v.name) }
        var v = v
        if v.fromOnePassword { v.value = v.value.trimmingCharacters(in: .whitespacesAndNewlines); v.secret = true }
        if memory { stored[v.name] = v; return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: v.name]
        let attrs: [String: Any] = [kSecValueData as String: Data(v.value.utf8), kSecAttrComment as String: v.fromOnePassword ? "1password" : (v.secret ? "secret" : "plain"),
                                    kSecAttrLabel as String: "Greenroom variable \(v.name)"]
        var status = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = match.merging(attrs) { $1 }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func remove(_ name: String) {
        if memory { stored[name] = nil; return }
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        SecItemDelete(match as CFDictionary)
    }

    // MARK: 1Password

    /// `vars` with each 1Password reference replaced by what 1Password holds (secret). Blocks while 1Password asks the
    /// person to approve; never on the main thread. Throws at the first that cannot be read, naming it.
    static func resolved(_ vars: [Variable], env: [String: String]) throws -> [Variable] {
        try vars.map { v in
            guard v.fromOnePassword else { return v }
            switch OnePassword.read(v.value, env: env) {
            case .success(let value): return Variable(name: v.name, value: value, secret: true)
            case .failure(let f): throw Failure.onePassword(v.name, f)
            }
        }
    }

    // MARK: Masking

    /// The secret values to take out of text that is shown or kept (three characters or more: shorter ones would
    /// mask ordinary words).
    func secrets() -> [String] { Self.secrets(of: all()) }

    static func secrets(of vars: [Variable]) -> [String] {
        vars.filter { $0.secret && $0.value.count >= 3 }.map(\.value).sorted { $0.count > $1.count }
    }

    static func mask(_ text: String, _ secrets: [String]) -> String {
        var t = text
        for s in secrets where t.contains(s) { t = t.replacingOccurrences(of: s, with: "••••") }
        return t
    }
}
