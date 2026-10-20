import SwiftUI

/// btop-style arrangement: CPU box across the top; below it the side panels (mem, sensors,
/// disks, net — one column when they fit, else two) and the process table on the right. Compact mode (⌘2)
/// drops the table: mem, sensors and disks+net side by side. The header occupies the
/// transparent titlebar row.
struct ContentView: View {
    static let minWidth: CGFloat = 1040
    static let sideColumnWidth: CGFloat = 250
    static let minHeight: CGFloat = 720   // fits the two-column side panels

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
                    SidePanels(columnWidth: Self.sideColumnWidth)
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

/// mem, sensors, disks and net. One column when all four fit the available height (the process
/// table gets the width), otherwise two. Either way the panels stretch to fill the height:
/// their history graphs absorb the extra space.
///
/// The decision reuses geometry the layout computes anyway: the panels' heights minus the
/// graphs' slack (how far each is stretched past its minimum) is the height one column needs.
/// That only changes on resize or structural changes (a disk mounts), unlike `ViewThatFits`,
/// which re-measured both arrangements on every refresh (~2% CPU).
private struct SidePanels: View {
    let columnWidth: CGFloat
    private static let spacing: CGFloat = 8
    static let panelIDs = ["mem", "sensors", "disks", "net"]

    @State private var singleColumn = false
    @State private var available: CGFloat = 0
    @State private var metrics: [String: SidePanelMetrics] = [:]

    var body: some View {
        Group {
            if singleColumn {
                VStack(spacing: Self.spacing) {
                    MemoryPanel().sidePanel("mem")
                    SensorsPanel().sidePanel("sensors")
                    DiskPanel().sidePanel("disks")
                    NetworkPanel().sidePanel("net")
                }
                .frame(width: columnWidth)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: Self.spacing) {
                        MemoryPanel().sidePanel("mem")
                        SensorsPanel().sidePanel("sensors")
                    }
                    .frame(width: columnWidth)
                    VStack(spacing: Self.spacing) {
                        DiskPanel().sidePanel("disks")
                        NetworkPanel().sidePanel("net")
                    }
                    .frame(width: columnWidth)
                }
            }
        }
        // minHeight 0: the stacked column must not raise the window's minimum size (that made
        // the window grow to fit it); the window minimum comes from the two-column layout.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0; decide() }
        .onPreferenceChange(SidePanelMetricsKey.self) { metrics = $0; decide() }
    }

    private func decide() {
        // A panel's minimum height = its height minus how far its graph is stretched; that's the
        // same in either arrangement, so the decision can't flip-flop.
        guard available > 0, Self.panelIDs.allSatisfy({ (metrics[$0]?.height ?? 0) > 0 }) else { return }
        let minimums = Self.panelIDs.reduce(0) { $0 + metrics[$1]!.height - metrics[$1]!.slack }
        let needed = minimums + CGFloat(Self.panelIDs.count - 1) * Self.spacing
        let single = needed <= available + 0.5
        if single != singleColumn { singleColumn = single }
    }
}

struct SidePanelMetrics: Equatable {
    var height: CGFloat = 0     // the panel's laid-out height
    var slack: CGFloat = 0      // how far its graph is stretched past its minimum
}

/// Per-panel metrics, merged from the panel (height) and its graph (slack) in one preference so
/// every decision sees a consistent snapshot.
struct SidePanelMetricsKey: PreferenceKey {
    static let defaultValue: [String: SidePanelMetrics] = [:]
    static func reduce(value: inout [String: SidePanelMetrics], nextValue: () -> [String: SidePanelMetrics]) {
        for (id, m) in nextValue() {
            var merged = value[id] ?? SidePanelMetrics()
            merged.height += m.height
            merged.slack += m.slack
            value[id] = merged
        }
    }
}

/// Which side panel a graph belongs to (set by `.sidePanel(_:)`).
private struct SidePanelIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sidePanelID: String? {
        get { self[SidePanelIDKey.self] }
        set { self[SidePanelIDKey.self] = newValue }
    }
}

extension View {
    /// Marks a side panel and reports its height (see `SidePanels`).
    func sidePanel(_ id: String) -> some View {
        environment(\.sidePanelID, id)
            .background(GeometryReader { geo in
                Color.clear.preference(key: SidePanelMetricsKey.self,
                                       value: [id: SidePanelMetrics(height: geo.size.height)])
            })
    }

    /// A side-panel graph: at least `minHeight`, grows to fill the column, and reports how far it
    /// is stretched (see `SidePanels`).
    func sidePanelGraph(minHeight: CGFloat) -> some View {
        modifier(SidePanelGraphModifier(minHeight: minHeight))
    }
}

private struct SidePanelGraphModifier: ViewModifier {
    let minHeight: CGFloat
    @Environment(\.sidePanelID) private var panel

    func body(content: Content) -> some View {
        content
            .frame(minHeight: minHeight, idealHeight: minHeight, maxHeight: .infinity)
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: SidePanelMetricsKey.self,
                    value: panel.map { [$0: SidePanelMetrics(slack: max(geo.size.height - minHeight, 0))] } ?? [:])
            })
    }
}
