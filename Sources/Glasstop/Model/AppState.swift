import Foundation
import Observation

/// UI/window state shared between AppKit (panel, menus, status item) and SwiftUI.
/// Persisted in UserDefaults except click-through, which always starts off (a window that
/// ignores the mouse on launch would be confusing).
@Observable
final class AppState {
    private enum Key {
        static let onTop = "alwaysOnTop"
        static let compact = "compactMode"
        static let opacity = "windowOpacity"
        static let hotKey = "globalHotKeyEnabled"
    }

    private(set) var alwaysOnTop: Bool
    private(set) var compact: Bool
    private(set) var opacity: Double              // 0.3...1
    private(set) var clickThrough = false
    private(set) var hotKeyEnabled: Bool
    private(set) var samplerSettings = SamplerSettings.load()
    /// Bumped by ⌘F; the process panel focuses its filter field when it changes.
    private(set) var focusFilterRequest = 0

    /// Set by AppDelegate to apply changes to the NSPanel, menus and status item.
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        let d = UserDefaults.standard
        alwaysOnTop = d.object(forKey: Key.onTop) as? Bool ?? true
        compact = d.bool(forKey: Key.compact)
        opacity = min(max(d.object(forKey: Key.opacity) as? Double ?? 1, 0.3), 1)
        hotKeyEnabled = d.bool(forKey: Key.hotKey)
    }

    func setAlwaysOnTop(_ on: Bool) {
        alwaysOnTop = on
        UserDefaults.standard.set(on, forKey: Key.onTop)
        onChange?()
    }

    func setCompact(_ on: Bool) {
        guard on != compact else { return }
        compact = on
        UserDefaults.standard.set(on, forKey: Key.compact)
        onChange?()
    }

    func setOpacity(_ value: Double) {
        opacity = min(max(value, 0.3), 1)
        UserDefaults.standard.set(opacity, forKey: Key.opacity)
        onChange?()
    }

    func setClickThrough(_ on: Bool) {
        clickThrough = on
        onChange?()
    }

    func setHotKeyEnabled(_ on: Bool) {
        hotKeyEnabled = on
        UserDefaults.standard.set(on, forKey: Key.hotKey)
        onChange?()
    }

    func setSamplerSettings(_ new: SamplerSettings) {
        var settings = new
        settings.interval = SamplerSettings.normalized(new.interval)
        guard settings != samplerSettings else { return }
        samplerSettings = settings
        settings.save()
        onChange?()
    }

    func requestFilterFocus() { focusFilterRequest &+= 1 }
}
