import AppKit
import SwiftUI

/// Greenroom > Settings… (⌘,): what the app may send, in one place.
final class SettingsWindow: NSWindowController {
    static let shared = SettingsWindow()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.contentView = NSHostingView(rootView: SettingsView())   // fresh values each time
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @State private var automatic = Updates.shared.checksAutomatically

    var body: some View {
        Form {
            Section("Updates") {
                if Updates.shared.available {
                    Toggle("Check for updates automatically", isOn: $automatic)
                        .onChange(of: automatic) { _, on in Updates.shared.checksAutomatically = on }
                    HStack {
                        Text(lastChecked).foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { Updates.shared.checkForUpdates(nil) }
                    }
                    Text("A check asks GitHub for the list of Greenroom versions. It sends no identifier and nothing about your Mac or your APKs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Updates are off in this build (not a packaged app).").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var lastChecked: String {
        guard let d = Updates.shared.lastChecked else { return "Never checked" }
        return "Last checked " + d.formatted(.relative(presentation: .named))
    }
}
