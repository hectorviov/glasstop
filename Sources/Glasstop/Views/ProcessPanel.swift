import AppKit
import SwiftUI

struct ProcessPanel: View {
    @Environment(Sampler.self) private var sampler
    @Environment(AppState.self) private var appState
    @AppStorage("processFilter") private var filter = ""
    @FocusState private var filterFocused: Bool

    private var rows: [ProcessRow] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return sampler.processes }
        return sampler.processes.filter {
            $0.name.localizedCaseInsensitiveContains(f)
                || $0.path.localizedCaseInsensitiveContains(f)
                || $0.user.localizedCaseInsensitiveContains(f)
                || String($0.pid).hasPrefix(f)
        }
    }

    var body: some View {
        let rows = self.rows
        Panel(title: "proc", tint: .blue, trailing: "\(rows.count)") {
            TextField("filter (⌘F)", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 200)
                .focused($filterFocused)
                .onChange(of: appState.focusFilterRequest) { filterFocused = true }
        } content: {
            ProcessTable(rows: rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// NSTableView instead of SwiftUI Table (whose row diffing triggered AppKit's "reentrant
/// operation in its NSTableView delegate" warning). Each row is one view that draws all of
/// its columns in a single pass: no per-cell NSTextFields, so a refresh only redraws rows
/// whose content actually changed. Columns still provide headers, sorting, resizing and
/// reordering.
struct ProcessTable: NSViewRepresentable {
    let rows: [ProcessRow]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.rowHeight = 17
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = false   // translucent stripes drawn by the rows
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for column in Column.allCases {
            let c = NSTableColumn(identifier: column.identifier)
            c.title = column.title
            c.width = column.width
            c.minWidth = column.minWidth
            c.resizingMask = column.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.headerCell.alignment = column.alignment
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.ascendingByDefault)
            table.addTableColumn(c)
        }
        // Column order/widths persist via autosave; the sort order is saved by the coordinator.
        table.autosaveName = "ProcessTable"
        table.autosaveTableColumns = true
        table.sortDescriptors = [Coordinator.savedSortDescriptor()]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true      // fallback if the user widens columns past the view
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.observeResizes(of: scroll.contentView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(rows)
    }

    enum Column: String, CaseIterable {
        case pid, name, command, threads, user, memory, cpu

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var title: String {
            switch self {
            case .pid: return "PID"
            case .name: return "Name"
            case .command: return "Command"
            case .threads: return "Thr"
            case .user: return "User"
            case .memory: return "Memory"
            case .cpu: return "CPU%"
            }
        }
        var width: CGFloat {
            switch self {
            case .pid: return 50
            case .name: return 140
            case .command: return 130
            case .threads: return 30
            case .user: return 72
            case .memory: return 66
            case .cpu: return 60
            }
        }
        var minWidth: CGFloat { min(width, 34) }
        var flexible: Bool { self == .name || self == .command }
        var alignment: NSTextAlignment {
            switch self {
            case .pid, .threads, .memory, .cpu: return .right
            default: return .left
            }
        }
        var ascendingByDefault: Bool { self == .name || self == .command || self == .user || self == .pid }

        /// Text and color for one cell.
        func content(_ r: ProcessRow) -> (String, NSColor) {
            let dim = NSColor.tertiaryLabelColor
            switch self {
            case .pid: return (String(r.pid), r.accessible ? .secondaryLabelColor : dim)
            case .name: return (r.name, .labelColor)
            case .command: return (r.path, r.accessible ? .secondaryLabelColor : dim)
            case .threads: return (r.accessible ? String(r.threads) : "—", r.accessible ? .labelColor : dim)
            case .user: return (r.user, r.accessible ? .secondaryLabelColor : dim)
            case .memory: return (r.accessible ? formatBytes(r.memory) : "—", r.accessible ? .labelColor : dim)
            case .cpu:
                guard r.accessible else { return ("—", dim) }
                // Quantized so tiny load changes don't recolor the row.
                let color = r.cpu >= 1 ? Palette.loadNS((min(r.cpu, 100) / 5).rounded() * 5) : .secondaryLabelColor
                return (String(format: "%.1f", r.cpu), color)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var rows: [ProcessRow] = []
        private var resizeObserver: NSObjectProtocol?

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

        /// Programmatic tables don't reliably shrink their columns with the scroll view, so the
        /// flexible columns (Name, Command) are fitted to the visible width on every resize,
        /// keeping their current proportions.
        func observeResizes(of clip: NSClipView) {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak clip] _ in
                guard let clip else { return }
                MainActor.assumeIsolated { self?.fitColumns(to: clip.bounds.width) }
            }
        }

        private func fitColumns(to available: CGFloat) {
            guard let tableView, available > 0 else { return }
            let columns = tableView.tableColumns
            let spacing = tableView.intercellSpacing.width * CGFloat(columns.count)
            let flexible = columns.filter { Column(rawValue: $0.identifier.rawValue)?.flexible == true }
            let fixed = columns.filter { !flexible.contains($0) }.reduce(0) { $0 + $1.width }
            let room = available - fixed - spacing
            let current = flexible.reduce(0) { $0 + $1.width }
            guard !flexible.isEmpty, current > 0, abs(room - current) > 0.5 else { return }
            for column in flexible {
                column.width = max(column.minWidth, (room * column.width / current).rounded(.down))
            }
        }
        private var selectedPID: pid_t?
        private var isUpdating = false
        private static let rowIdentifier = NSUserInterfaceItemIdentifier("processRow")

        /// Rows are positional: adjust the count, then hand each visible row view its new
        /// data (it redraws only if the data differs). No reloadData().
        func update(_ newRows: [ProcessRow]) {
            guard let tableView else { return }
            let oldCount = rows.count
            rows = sorted(newRows)
            isUpdating = true
            if rows.count > oldCount {
                tableView.insertRows(at: IndexSet(oldCount..<rows.count), withAnimation: [])
            } else if rows.count < oldCount {
                tableView.removeRows(at: IndexSet(rows.count..<oldCount), withAnimation: [])
            }
            refreshVisibleRows()
            restoreSelection()
            isUpdating = false
        }

        private func refreshVisibleRows(forceRedraw: Bool = false) {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            for i in visible.location..<min(visible.location + visible.length, rows.count) {
                guard let view = tableView.rowView(atRow: i, makeIfNecessary: false) as? ProcessRowView else { continue }
                view.process = rows[i]
                if forceRedraw { view.needsDisplay = true }
            }
        }

        private func restoreSelection() {
            guard let tableView else { return }
            if let pid = selectedPID, let i = rows.firstIndex(where: { $0.pid == pid }) {
                if tableView.selectedRow != i {
                    tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                }
            } else if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
        }

        private func sorted(_ input: [ProcessRow]) -> [ProcessRow] {
            guard let descriptor = tableView?.sortDescriptors.first,
                  let key = descriptor.key.flatMap(Column.init(rawValue:)) else { return input }
            let asc = descriptor.ascending
            // Ties break on pid so equal rows never swap places between refreshes.
            return input.sorted { a, b in
                let order: ComparisonResult
                switch key {
                case .pid: order = compare(a.pid, b.pid)
                case .name: order = a.name.localizedCaseInsensitiveCompare(b.name)
                case .command: order = a.path.localizedCaseInsensitiveCompare(b.path)
                case .threads: order = compare(a.threads, b.threads)
                case .user: order = a.user.localizedCaseInsensitiveCompare(b.user)
                case .memory: order = compare(a.memory, b.memory)
                case .cpu: order = compare(a.cpu, b.cpu)
                }
                if order == .orderedSame { return a.pid < b.pid }
                return asc ? order == .orderedAscending : order == .orderedDescending
            }
        }

        private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? ProcessRowView)
                ?? ProcessRowView(identifier: Self.rowIdentifier)
            view.table = tableView
            view.striped = row % 2 == 1
            view.process = row < rows.count ? rows[row] : nil
            return view
        }

        /// The row view draws every column itself.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

        private static let sortKeyDefault = "processSortKey"
        private static let sortAscendingDefault = "processSortAscending"

        static func savedSortDescriptor() -> NSSortDescriptor {
            let d = UserDefaults.standard
            guard let key = d.string(forKey: sortKeyDefault).flatMap(Column.init(rawValue:)) else {
                return NSSortDescriptor(key: Column.cpu.rawValue, ascending: false)
            }
            return NSSortDescriptor(key: key.rawValue, ascending: d.bool(forKey: sortAscendingDefault))
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if let d = tableView.sortDescriptors.first, let key = d.key {
                UserDefaults.standard.set(key, forKey: Self.sortKeyDefault)
                UserDefaults.standard.set(d.ascending, forKey: Self.sortAscendingDefault)
            }
            rows = sorted(rows)
            refreshVisibleRows()
            restoreSelection()
        }

        func tableViewColumnDidResize(_ notification: Notification) { refreshVisibleRows(forceRedraw: true) }
        func tableViewColumnDidMove(_ notification: Notification) { refreshVisibleRows(forceRedraw: true) }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let tableView else { return }
            let i = tableView.selectedRow
            selectedPID = i >= 0 && i < rows.count ? rows[i].pid : nil
        }
    }
}

/// Draws one process row (all columns) in a single pass, at the table's column positions.
final class ProcessRowView: NSTableRowView {
    weak var table: NSTableView?
    var process: ProcessRow? {
        didSet { if process != oldValue { needsDisplay = true } }
    }
    var striped = false {
        didSet { if striped != oldValue { needsDisplay = true } }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    /// Translucent stripes (instead of NSTableView's opaque alternating colors) so the
    /// window's material shows through.
    override func drawBackground(in dirtyRect: NSRect) {
        guard striped else { return }
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        dirtyRect.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)   // background + selection
        guard let process, let table, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let selected = isSelected && isEmphasized
        let baseline = floor((bounds.height - (Self.font.ascender - Self.font.descender)) / 2 + Self.font.ascender)
        let inset = table.intercellSpacing.width / 2

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // row views are flipped
        for (index, tableColumn) in table.tableColumns.enumerated() {
            guard let column = ProcessTable.Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            let columnRect = table.rect(ofColumn: index)
            let x = columnRect.minX + inset
            let width = columnRect.width - 2 * inset
            guard width > 4, x < dirtyRect.maxX, x + width > dirtyRect.minX else { continue }
            let (text, color) = column.content(process)
            let line = TextLineCache.shared.line(text, width: width, column: column, font: Self.font)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let dx = column.alignment == .right ? max(width - lineWidth, 0) : 0
            ctx.setFillColor((selected ? NSColor.alternateSelectedControlTextColor : color).cgColor)
            ctx.textPosition = CGPoint(x: x + dx, y: baseline)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    override func accessibilityLabel() -> String? {
        guard let p = process else { return nil }
        return "\(p.name), PID \(p.pid), CPU \(String(format: "%.1f", p.cpu)) percent, memory \(formatBytes(p.memory))"
    }
}

/// Typeset (and truncated) CoreText lines, keyed by text + column width. Typesetting and
/// truncation dominate table drawing; names, paths and users rarely change, they just move
/// between rows as the sort order shifts. Color comes from the context, so it isn't part of
/// the key. Bounded: cleared when it grows past `limit` entries.
final class TextLineCache {
    static let shared = TextLineCache()
    private static let limit = 4000

    private struct Key: Hashable {
        let text: String
        let width: Int
        let column: ProcessTable.Column
    }

    private var lines: [Key: CTLine] = [:]

    func line(_ text: String, width: CGFloat, column: ProcessTable.Column, font: NSFont) -> CTLine {
        let key = Key(text: text, width: Int(width.rounded(.down)), column: column)
        if let cached = lines[key] { return cached }
        if lines.count >= Self.limit { lines.removeAll(keepingCapacity: true) }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var line = full
        if CGFloat(CTLineGetTypographicBounds(full, nil, nil, nil)) > CGFloat(key.width) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(full, Double(key.width), column == .command ? .middle : .end, ellipsis) ?? full
        }
        lines[key] = line
        return line
    }
}
