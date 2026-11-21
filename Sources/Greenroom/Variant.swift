import AppKit

/// Which copy of Greenroom this is: the release, or the debug build that `scripts/bundle.sh --variant debug` makes to
/// install beside it (Info.plist's `GreenroomVariant`). The debug copy has its own name, an orange icon and an orange
/// line along the window's top, and its own state folder, so both can run at once without meeting: simulators, app
/// data, recordings and the agent endpoint stay apart.
enum Variant {
    static let isDebug = (Bundle.main.object(forInfoDictionaryKey: "GreenroomVariant") as? String) == "debug"
    /// The app's name in its menus and window.
    static var name: String { isDebug ? "Greenroom Debug" : "Greenroom" }
    /// The folder in Application Support that holds the state.
    static var stateFolder: String { isDebug ? "Greenroom Debug" : "Greenroom" }
    /// The debug copy's colour, the icon's plate.
    static let debugColor = NSColor(srgbRed: 246/255, green: 146/255, blue: 48/255, alpha: 1)

    /// The debug copy's orange line along the window's top edge, above the toolbar's buttons. (A title bar accessory
    /// is sized by AppKit, ~20 pt under the toolbar, and covers the stage, which runs under the title bar; a badge in
    /// the bar sat on the toolbar's own buttons.)
    static func addBadge(to window: NSWindow) {
        guard isDebug, let frame = window.contentView?.superview else { return }
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = debugColor.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(line, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            line.topAnchor.constraint(equalTo: frame.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 3),
        ])
    }
}
