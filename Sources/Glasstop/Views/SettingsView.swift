import ServiceManagement
import SwiftUI

/// Settings window (Glasstop → Settings…, ⌘,). Changes apply immediately.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Sampling") {
                Stepper(value: binding(\.interval), in: SamplerSettings.intervalRange,
                        step: SamplerSettings.intervalStep) {
                    HStack {
                        Text("Refresh interval")
                        Spacer()
                        Text(milliseconds(appState.samplerSettings.interval)).monospacedDigit()
                    }
                }
                Picker("History length", selection: binding(\.historySeconds)) {
                    ForEach(SamplerSettings.historyLengths, id: \.self) { Text("\($0 / 60) min").tag($0) }
                }
                Picker("Process list refresh", selection: binding(\.processInterval)) {
                    ForEach(SamplerSettings.processIntervals, id: \.self) { Text(seconds($0)).tag($0) }
                }
                Text("100 ms steps (also the − / + arrows in the header). Faster refresh costs more CPU; 1 s is the default for both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window") {
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: Binding(get: { appState.opacity }, set: { appState.setOpacity($0) }),
                               in: 0.3...1)
                        Text("\(Int((appState.opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Toggle("Keep on top", isOn: Binding(get: { appState.alwaysOnTop },
                                                    set: { appState.setAlwaysOnTop($0) }))
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin))
                if loginStatus == .requiresApproval {
                    Text("Approve Glasstop in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Global hotkey \(GlobalHotKey.displayString) shows/hides the window",
                       isOn: Binding(get: { appState.hotKeyEnabled }, set: { appState.setHotKeyEnabled($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SamplerSettings, T>) -> Binding<T> {
        Binding(get: { appState.samplerSettings[keyPath: keyPath] },
                set: { value in
                    var s = appState.samplerSettings
                    s[keyPath: keyPath] = value
                    appState.setSamplerSettings(s)
                })
    }

    private func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%.0f ms", value * 1000)
    }

    private func seconds(_ value: TimeInterval) -> String {
        value < 1 ? String(format: "%.2g s", value) : String(format: "%.0f s", value)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}
