import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let appState = AppState()
    private lazy var sampler = Sampler(settings: appState.samplerSettings)
    private var settingsWindow: NSWindow?
    private var panel: NSPanel?
    private var hosting: NSView?
    private var statusItem: StatusItemController?
    private lazy var hotKey = GlobalHotKey { [weak self] in self?.togglePanel() }
    private var appliedCompact = false
    private var menuItems: [String: NSMenuItem] = [:]
    /// Opts out of App Nap (timer throttling while the window is covered would make the menu
    /// bar CPU % lag); the system can still idle-sleep.
    private var activity: NSObjectProtocol?

    private static func frameName(compact: Bool) -> String { compact ? "GlasstopCompactPanel" : "GlasstopMainPanel" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let root = ContentView()
            .environment(sampler)
            .environment(appState)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.minSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = hosting

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
        panel.delegate = self
        appliedCompact = appState.compact
        let frameName = Self.frameName(compact: appliedCompact)
        if !panel.setFrameUsingName(frameName) { panel.center() }
        _ = panel.setFrameAutosaveName(frameName)
        self.panel = panel

        // Hidden, minimized or fully covered: stop publishing to SwiftUI (sampling continues).
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.sampler.isVisible = panel.occlusionState.contains(.visible)
            }
        }

        let status = StatusItemController(appState: appState)
        status.togglePanel = { [weak self] in self?.togglePanel() }
        status.isPanelVisible = { [weak self] in self?.panel?.isVisible == true }
        status.openSettings = { [weak self] in self?.showSettings(nil) }
        statusItem = status
        sampler.onTick = { [weak status] snapshot in
            if let cpu = snapshot.cpu { status?.update(cpu: cpu.total) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampler.resetAfterWake() }
        }

        appState.onChange = { [weak self] in self?.applyState() }
        applyState()

        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Live system monitoring")
        showPanel()
        sampler.start()
    }

    /// The panel's close button hides it; Glasstop keeps running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let panel { panel.saveFrame(usingName: Self.frameName(compact: appliedCompact)) }
        sampler.stop()
    }

    // MARK: Panel visibility

    private func showPanel() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible && panel.occlusionState.contains(.visible) && !panel.isMiniaturized {
            panel.orderOut(nil)
        } else {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            showPanel()
        }
    }

    // MARK: State → window

    private func applyState() {
        guard let panel else { return }
        let onTop = appState.alwaysOnTop
        panel.isFloatingPanel = onTop
        panel.level = onTop ? .floating : .normal
        // On top: follow the user to every Space, including other apps' fullscreen ones.
        // Off: an ordinary window that stays on its own Space.
        panel.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        panel.alphaValue = appState.opacity
        panel.ignoresMouseEvents = appState.clickThrough

        sampler.apply(appState.samplerSettings)
        if appState.hotKeyEnabled {
            if !hotKey.register() {
                NSLog("Glasstop: global hotkey %@ is unavailable (taken by another app?)", GlobalHotKey.displayString)
            }
        } else {
            hotKey.unregister()
        }
        applyCompact()

        menuItems["onTop"]?.state = onTop ? .on : .off
        menuItems["full"]?.state = appState.compact ? .off : .on
        menuItems["compact"]?.state = appState.compact ? .on : .off
        menuItems["clickThrough"]?.state = appState.clickThrough ? .on : .off
    }

    /// Each mode remembers its own frame. SwiftUI re-lays out on the next runloop pass, so
    /// the new frame is applied after that (the window's min size has changed by then).
    private func applyCompact() {
        guard let panel, appState.compact != appliedCompact else { return }
        panel.saveFrame(usingName: Self.frameName(compact: appliedCompact))
        appliedCompact = appState.compact
        panel.setFrameAutosaveName("")
        let compact = appliedCompact
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, compact == self.appliedCompact else { return }
            let name = Self.frameName(compact: compact)
            if !panel.setFrameUsingName(name) {
                // First time in this mode: keep the top-left corner, fit the height.
                self.hosting?.layoutSubtreeIfNeeded()
                let height = compact ? (self.hosting?.fittingSize.height ?? 560) : 820
                var frame = panel.frame
                frame.origin.y = frame.maxY - height
                frame.size.height = height
                panel.setFrame(frame, display: true)
            }
            panel.setFrameAutosaveName(name)
        }
    }

    // MARK: Menu (not visible for an accessory app, but provides the key equivalents)

    @objc private func toggleAlwaysOnTop(_ sender: Any?) { appState.setAlwaysOnTop(!appState.alwaysOnTop) }
    @objc private func showFull(_ sender: Any?) { appState.setCompact(false) }
    @objc private func showCompact(_ sender: Any?) { appState.setCompact(true) }
    @objc private func toggleClickThrough(_ sender: Any?) { appState.setClickThrough(!appState.clickThrough) }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environment(appState)))
            window.title = "Glasstop Settings"
            window.styleMask = [.titled, .closable]
            window.level = .floating            // above the (floating) main panel
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// ⌘F: full mode, panel visible, focus the process filter.
    @objc private func findProcess(_ sender: Any?) {
        appState.setCompact(false)
        showPanel()
        DispatchQueue.main.async { [weak self] in self?.appState.requestFilterFocus() }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Glasstop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("settings", "Settings…", #selector(showSettings(_:)), ","))
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
        editMenu.addItem(.separator())
        editMenu.addItem(item("find", "Find Process", #selector(findProcess(_:)), "f"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("onTop", "Keep on Top", #selector(toggleAlwaysOnTop(_:)), "t"))
        windowMenu.addItem(item("full", "Full Mode", #selector(showFull(_:)), "1"))
        windowMenu.addItem(item("compact", "Compact Mode", #selector(showCompact(_:)), "2"))
        windowMenu.addItem(item("clickThrough", "Click-Through", #selector(toggleClickThrough(_:)), ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func item(_ key: String, _ title: String, _ action: Selector, _ keyEquivalent: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = self
        menuItems[key] = menuItem
        return menuItem
    }
}
