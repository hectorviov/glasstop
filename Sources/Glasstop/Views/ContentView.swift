import SwiftUI

/// btop-style arrangement: CPU box across the top; memory + sensors on the left and the
/// process table on the right below it. The header occupies the transparent titlebar row.
struct ContentView: View {
    static let minSize = CGSize(width: 860, height: 680)

    var body: some View {
        VStack(spacing: 8) {
            HeaderBar()
                .padding(.trailing, -4)
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
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12))
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .ignoresSafeArea(.container, edges: .top)
    }
}
