import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = Sampler()
    private let appState = AppState()
    private var panel: NSPanel?
    private var onTopMenuItem: NSMenuItem?
    private static let frameName = "GlasstopMainPanel"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let root = ContentView()
            .environment(sampler)
            .environment(appState)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.minSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // Frosted material behind everything; stays vibrant while the app is inactive (the
        // usual state for a floating monitor).
        let material = NSVisualEffectView()
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Glasstop"
        panel.titleVisibility = .hidden                 // the header row lives in the titlebar
        panel.titlebarAppearsTransparent = true
        panel.contentView = material
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false                 // panels hide on deactivate by default
        if !panel.setFrameUsingName(Self.frameName) { panel.center() }
        _ = panel.setFrameAutosaveName(Self.frameName)
        self.panel = panel

        applyAlwaysOnTop(appState.alwaysOnTop)
        appState.onAlwaysOnTopChange = { [weak self] on in self?.applyAlwaysOnTop(on) }

        // Hidden, minimized or fully covered: stop publishing to SwiftUI (sampling continues).
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.sampler.isVisible = panel.occlusionState.contains(.visible)
            }
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        sampler.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { sampler.stop() }

    // MARK: Always on top

    private func applyAlwaysOnTop(_ on: Bool) {
        panel?.isFloatingPanel = on
        panel?.level = on ? .floating : .normal
        // On top: follow the user to every Space, including other apps' fullscreen ones.
        // Off: an ordinary window that stays on its own Space.
        panel?.collectionBehavior = on ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        onTopMenuItem?.state = on ? .on : .off
    }

    @objc private func toggleAlwaysOnTop(_ sender: Any?) {
        appState.setAlwaysOnTop(!appState.alwaysOnTop)
    }

    // MARK: Menu (needed for ⌘Q and for ⌘C/⌘V in the filter field)

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Glasstop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Glasstop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Glasstop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let onTop = NSMenuItem(title: "Keep on Top", action: #selector(toggleAlwaysOnTop(_:)), keyEquivalent: "t")
        onTop.target = self
        onTop.state = appState.alwaysOnTop ? .on : .off
        windowMenu.addItem(onTop)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        onTopMenuItem = onTop

        NSApp.mainMenu = main
    }
}
