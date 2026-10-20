import AppKit

/// Menu bar item: shows total CPU %. Left click shows/hides the panel; right click (or
/// ⌃-click) opens the menu with every window option. As an accessory app Glasstop has no
/// Dock icon or visible main menu, so this is its always-reachable handle — it is how you
/// get out of click-through mode.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let appState: AppState
    private let menu = NSMenu()
    private var lastTitle = ""

    // Callbacks into AppDelegate.
    var togglePanel: () -> Void = {}
    var isPanelVisible: () -> Bool = { true }

    private let showItem = NSMenuItem(title: "Show Glasstop", action: #selector(toggle(_:)), keyEquivalent: "")
    private let onTopItem = NSMenuItem(title: "Keep on Top", action: #selector(toggleOnTop(_:)), keyEquivalent: "t")
    private let compactItem = NSMenuItem(title: "Compact Mode", action: #selector(toggleCompact(_:)), keyEquivalent: "2")
    private let clickThroughItem = NSMenuItem(title: "Click-Through", action: #selector(toggleClickThrough(_:)), keyEquivalent: "")
    private let hotKeyItem = NSMenuItem(title: "Global Hotkey \(GlobalHotKey.displayString)", action: #selector(toggleHotKey(_:)), keyEquivalent: "")
    private let opacitySlider = NSSlider(value: 1, minValue: 0.3, maxValue: 1, target: nil, action: nil)

    init(appState: AppState) {
        self.appState = appState
        super.init()

        if let button = item.button {
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = "CPU –"
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Glasstop — click to show/hide, right-click for options"
        }

        for menuItem in [showItem, onTopItem, compactItem, clickThroughItem, hotKeyItem] { menuItem.target = self }
        compactItem.keyEquivalentModifierMask = .command
        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(onTopItem)
        menu.addItem(compactItem)
        menu.addItem(clickThroughItem)
        menu.addItem(opacityMenuItem())
        menu.addItem(.separator())
        menu.addItem(hotKeyItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Glasstop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
    }

    /// Called on every sampler tick (also while the panel is hidden). Only touches the
    /// status bar when the rounded value changes.
    func update(cpu: Double) {
        let title = String(format: "CPU %2.0f%%", cpu)
        guard title != lastTitle else { return }
        lastTitle = title
        item.button?.title = title
    }

    // MARK: Menu

    private func opacityMenuItem() -> NSMenuItem {
        let label = NSTextField(labelWithString: "Opacity")
        label.font = .menuFont(ofSize: 0)
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        let stack = NSStackView(views: [label, opacitySlider])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 26)
        opacitySlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let menuItem = NSMenuItem()
        menuItem.view = stack
        return menuItem
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showItem.title = isPanelVisible() ? "Hide Glasstop" : "Show Glasstop"
        onTopItem.state = appState.alwaysOnTop ? .on : .off
        compactItem.state = appState.compact ? .on : .off
        clickThroughItem.state = appState.clickThrough ? .on : .off
        hotKeyItem.state = appState.hotKeyEnabled ? .on : .off
        opacitySlider.doubleValue = appState.opacity
    }

    // MARK: Actions

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu                     // attach just for this click…
            item.button?.performClick(nil)
            item.menu = nil                      // …so left clicks keep toggling the panel
        } else {
            togglePanel()
        }
    }

    @objc private func toggle(_ sender: Any?) { togglePanel() }
    @objc private func toggleOnTop(_ sender: Any?) { appState.setAlwaysOnTop(!appState.alwaysOnTop) }
    @objc private func toggleCompact(_ sender: Any?) { appState.setCompact(!appState.compact) }
    @objc private func toggleClickThrough(_ sender: Any?) { appState.setClickThrough(!appState.clickThrough) }
    @objc private func toggleHotKey(_ sender: Any?) { appState.setHotKeyEnabled(!appState.hotKeyEnabled) }
    @objc private func opacityChanged(_ sender: NSSlider) { appState.setOpacity(sender.doubleValue) }
}
