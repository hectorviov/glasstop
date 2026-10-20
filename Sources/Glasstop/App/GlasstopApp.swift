import AppKit

@main
enum GlasstopMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Regular Dock app with its own menu bar. Trade-off: a .regular app's windows never
        // join other apps' fullscreen Spaces (only .accessory/LSUIElement apps can); Keep on
        // Top still floats above ordinary windows on every desktop.
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
