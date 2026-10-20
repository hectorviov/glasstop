import SwiftUI

/// btop-style arrangement: CPU box across the top; below it a 2×2 block on the left
/// (mem | disks over sensors | net) and the process table on the right. Compact mode (⌘2)
/// drops the table: mem, sensors and disks+net side by side. The header occupies the
/// transparent titlebar row.
struct ContentView: View {
    static let minWidth: CGFloat = 1040
    static let sideColumnWidth: CGFloat = 250
    static let minHeight: CGFloat = 680

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 8) {
            HeaderBar()
                .padding(.trailing, -4)
            CPUPanel()
            if appState.compact {
                HStack(alignment: .top, spacing: 10) {
                    MemoryPanel().frame(maxHeight: .infinity, alignment: .top)
                    SensorsPanel().frame(maxHeight: .infinity, alignment: .top)
                    VStack(spacing: 8) {
                        DiskPanel()
                        NetworkPanel()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)   // equal-height panels
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 8) {
                        MemoryPanel()
                        SensorsPanel()
                        Spacer(minLength: 0)
                    }
                    .frame(width: Self.sideColumnWidth)
                    VStack(spacing: 8) {
                        DiskPanel()
                        NetworkPanel()
                        Spacer(minLength: 0)
                    }
                    .frame(width: Self.sideColumnWidth)
                    ProcessPanel()
                }
            }
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        .frame(minWidth: Self.minWidth, minHeight: appState.compact ? nil : Self.minHeight,
               alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }
}
