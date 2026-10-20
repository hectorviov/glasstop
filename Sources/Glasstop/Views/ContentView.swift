import SwiftUI

/// btop-style arrangement: CPU box across the top; memory + sensors on the left and the
/// process table on the right below it.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            HeaderBar()
            CPUPanel()
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 8) {
                    MemoryPanel()
                    SensorsPanel()
                    Spacer(minLength: 0)
                }
                .frame(width: 280)
                ProcessPanel()
            }
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        .frame(minWidth: 860, minHeight: 680)
    }
}
