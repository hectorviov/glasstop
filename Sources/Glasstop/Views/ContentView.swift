import SwiftUI

/// btop-style arrangement: CPU box across the top; memory + sensors on the left and the
/// process table on the right below it.
struct ContentView: View {
    // TEMP experiment hook (remove): `open Glasstop.app --args -hide cpu,mem,sensors,proc`
    private let hide = Set((UserDefaults.standard.string(forKey: "hide") ?? "").split(separator: ",").map(String.init))

    var body: some View {
        VStack(spacing: 8) {
            HeaderBar()
            if !hide.contains("cpu") {
                CPUPanel()
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 8) {
                    if !hide.contains("mem") { MemoryPanel() }
                    if !hide.contains("sensors") { SensorsPanel() }
                    Spacer(minLength: 0)
                }
                .frame(width: 280)
                if !hide.contains("proc") { ProcessPanel() } else { Spacer() }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        .frame(minWidth: 860, minHeight: 680)
    }
}
