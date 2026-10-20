import Foundation
import Observation

/// UI/window state shared between AppKit (panel, menu) and SwiftUI.
@Observable
final class AppState {
    private static let onTopKey = "alwaysOnTop"

    private(set) var alwaysOnTop: Bool

    /// Set by AppDelegate to apply the change to the NSPanel + menu item.
    @ObservationIgnored var onAlwaysOnTopChange: ((Bool) -> Void)?

    init() {
        alwaysOnTop = UserDefaults.standard.object(forKey: Self.onTopKey) as? Bool ?? true
    }

    func setAlwaysOnTop(_ on: Bool) {
        alwaysOnTop = on
        UserDefaults.standard.set(on, forKey: Self.onTopKey)
        onAlwaysOnTopChange?(on)
    }
}
