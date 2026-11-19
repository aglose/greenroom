import AppKit

// `Greenroom --smoke APK` (CI and scripts/bundle.sh --check): runs the APK headless in the bundled engine until its
// first frame, prints the engine's output, and exits with its status. No window, no app.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--smoke"), i + 1 < arguments.count {
    let apk = URL(fileURLWithPath: arguments[i + 1])
    do {
        var status: Int32 = 1
        let instance = try Engine.shared.launch(apk: apk, options: ["--headless", "--exit-after-first-frame"])
        instance.process.waitUntilExit()
        status = instance.process.terminationStatus
        let log = (try? String(contentsOf: instance.log, encoding: .utf8)) ?? ""
        print(log, terminator: "")
        print("[greenroom] smoke: engine \(Engine.shared.version) exit \(status)")
        Engine.shared.stopAll()
        exit(status)
    } catch {
        FileHandle.standardError.write(Data("[greenroom] smoke failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
