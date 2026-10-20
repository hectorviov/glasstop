import AppKit

@main
enum GlasstopMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory (no Dock icon / menu bar) is required for the panel to float over other
        // apps' fullscreen Spaces; a .regular app's windows never join them. Menu key
        // equivalents (⌘T, ⌘V, ⌘Q) still work. Info.plist sets LSUIElement for the bundle.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
