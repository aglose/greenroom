import AppKit
import SwiftUI

/// The selectable app icons bundled in `Contents/Resources/Icons/`. Studio Bay is the default baked into `AppIcon.icns`.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case studioBay = "studio-bay"
    case liquidGlass = "liquid-glass"
    case spotlight = "spotlight"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studioBay: "Studio Bay"
        case .liquidGlass: "Liquid Glass"
        case .spotlight: "Spotlight"
        }
    }
}

/// Manages the chosen Dock and App Switcher icon, persisted in `UserDefaults`.
enum AppIcon {
    static let defaultsKey = "appIconStyle"
    static let didChangeNotification = Notification.Name("GreenroomAppIconDidChange")

    static var current: AppIconStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let style = AppIconStyle(rawValue: raw) else { return .studioBay }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            apply(newValue)
            NotificationCenter.default.post(name: didChangeNotification, object: newValue)
        }
    }

    /// Applies the chosen icon to `NSApp`. Leaves `applicationIconImage` nil for the default icon in a packaged `.app`
    /// so macOS renders the bundle's native `AppIcon.icns` directly.
    static func apply(_ style: AppIconStyle = current) {
        guard let app = NSApp else { return }
        if style == .studioBay, Bundle.main.bundleURL.pathExtension == "app" {
            app.applicationIconImage = nil
            return
        }
        app.applicationIconImage = image(for: style)
    }

    /// Loads the `.icns` image for `style`, preferring the bundled copy and falling back to `Resources/Icons/` when run
    /// unbundled during development.
    static func image(for style: AppIconStyle) -> NSImage? {
        if let url = Bundle.main.url(forResource: style.rawValue, withExtension: "icns", subdirectory: "Icons"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        let suffix = Variant.isDebug ? "-debug" : ""
        let rel = "Resources/Icons/\(style.rawValue)\(suffix).icns"
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(rel)
        if let img = NSImage(contentsOf: cwd) { return img }
        // Walk up from the executable in `.build/...` when launched from outside the repository root.
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(rel)
            if let img = NSImage(contentsOf: candidate) { return img }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// The App Icon picker shown in Settings (⌘,).
struct AppIconSection: View {
    @State private var selected = AppIcon.current

    var body: some View {
        Section("App Icon") {
            HStack(spacing: 12) {
                ForEach(AppIconStyle.allCases) { style in
                    let isSelected = selected == style
                    Button {
                        selected = style
                        AppIcon.current = style
                    } label: {
                        VStack(spacing: 6) {
                            if let img = AppIcon.image(for: style) {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 64, height: 64)
                            } else {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.quaternary)
                                    .frame(width: 54, height: 54)
                                    .padding(5)
                            }
                            Text(style.title)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                              lineWidth: isSelected ? 1.5 : 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Text("Studio Bay is the default. An alternate icon appears in the Dock and App Switcher while Greenroom is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppIcon.didChangeNotification)) { _ in
            selected = AppIcon.current
        }
    }
}
