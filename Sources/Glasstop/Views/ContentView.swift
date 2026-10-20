import SwiftUI

/// btop-style arrangement: CPU box across the top; memory + sensors on the left and the
/// process table on the right below it. Compact mode (⌘2) drops the table and puts memory
/// and sensors side by side. The header occupies the transparent titlebar row.
struct ContentView: View {
    static let minWidth: CGFloat = 860
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
                }
                .fixedSize(horizontal: false, vertical: true)   // equal-height panels
            } else {
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
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        .frame(minWidth: Self.minWidth, minHeight: appState.compact ? nil : Self.minHeight,
               alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }
}
