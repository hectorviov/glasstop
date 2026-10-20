import AppKit
import SwiftUI

struct ProcessPanel: View {
    @Environment(Sampler.self) private var sampler
    @Environment(AppState.self) private var appState
    @AppStorage("processFilter") private var filter = ""
    @AppStorage("processOnlyMine") private var onlyMine = false
    @AppStorage("processHideIdle") private var hideIdle = false
    @AppStorage("processTree") private var tree = false
    @FocusState private var filterFocused: Bool

    private static let myUID = getuid()

    private var rows: [ProcessRow] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty || onlyMine || hideIdle else { return sampler.processes }
        return sampler.processes.filter {
            (!onlyMine || $0.uid == Self.myUID)
                && (!hideIdle || $0.cpu > 0 || $0.memory > 0)
                && (f.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(f)
                    || $0.path.localizedCaseInsensitiveContains(f)
                    || $0.user.localizedCaseInsensitiveContains(f)
                    || String($0.pid).hasPrefix(f))
        }
    }

    var body: some View {
        let rows = self.rows
        Panel(title: "proc", tint: .blue, trailing: "\(rows.count)") {
            Menu {
                Toggle("Only My Processes", isOn: $onlyMine)
                Toggle("Hide Idle Processes", isOn: $hideIdle)
                Divider()
                Toggle("Tree View", isOn: $tree)
            } label: {
                Image(systemName: onlyMine || hideIdle || tree
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View options")
            TextField("filter (⌘F)", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 200)
                .focused($filterFocused)
                .onChange(of: appState.focusFilterRequest) { filterFocused = true }
        } content: {
            ProcessTable(rows: rows, tree: tree)
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
    var tree = false

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
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

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
        context.coordinator.tree = tree
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

        /// Secondary columns (pid, command, user) of your processes.
        private static let secondary = NSColor.labelColor.withAlphaComponent(0.65)
        /// Other users' processes: readable, but clearly a step below (no cpu/memory access).
        private static let restricted = NSColor.labelColor.withAlphaComponent(0.5)

        /// Text and color for one cell.
        func content(_ r: ProcessRow) -> (String, NSColor) {
            let dim = Self.restricted
            switch self {
            case .pid: return (String(r.pid), r.accessible ? Self.secondary : dim)
            case .name: return (r.name, .labelColor)
            case .command: return (r.path, r.accessible ? Self.secondary : dim)
            case .threads: return (r.accessible ? String(r.threads) : "—", r.accessible ? .labelColor : dim)
            case .user: return (r.user, r.accessible ? Self.secondary : dim)
            case .memory: return (r.accessible ? formatBytes(r.memory) : "—", r.accessible ? .labelColor : dim)
            case .cpu:
                guard r.accessible else { return ("—", dim) }
                // Quantized so tiny load changes don't recolor the row.
                let color = r.cpu >= 1 ? Palette.loadNS((min(r.cpu, 100) / 5).rounded() * 5) : Self.secondary
                return (String(format: "%.1f", r.cpu), color)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var tableView: NSTableView?
        private var rows: [ProcessRow] = []
        private var depths: [Int] = []          // tree depth per row (all 0 in flat mode)
        var tree = false
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
            (rows, depths) = ordered(newRows)
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
                view.depth = depths[i]
                view.process = rows[i]
                if forceRedraw { view.redrawContent() }
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

        /// Flat: sorted by the table's sort descriptor. Tree: parents before children, siblings
        /// sorted by the same descriptor.
        private func ordered(_ input: [ProcessRow]) -> ([ProcessRow], [Int]) {
            let less = comparator()
            guard tree else { return (input.sorted(by: less), Array(repeating: 0, count: input.count)) }

            let present = Set(input.map(\.pid))
            var children: [pid_t: [ProcessRow]] = [:]
            var roots: [ProcessRow] = []
            for row in input {
                if row.ppid != row.pid, present.contains(row.ppid) {
                    children[row.ppid, default: []].append(row)
                } else {
                    roots.append(row)
                }
            }
            var out: [ProcessRow] = [], depths: [Int] = [], seen = Set<pid_t>()
            out.reserveCapacity(input.count)
            depths.reserveCapacity(input.count)
            var stack: [(ProcessRow, Int)] = roots.sorted(by: less).reversed().map { ($0, 0) }
            while let (row, depth) = stack.popLast() {
                guard seen.insert(row.pid).inserted else { continue }
                out.append(row)
                depths.append(depth)
                for child in (children[row.pid] ?? []).sorted(by: less).reversed() { stack.append((child, depth + 1)) }
            }
            // Anything unreachable (a parent cycle from racing pid reuse) still gets listed.
            for row in input where !seen.contains(row.pid) {
                out.append(row)
                depths.append(0)
            }
            return (out, depths)
        }

        private func comparator() -> (ProcessRow, ProcessRow) -> Bool {
            guard let descriptor = tableView?.sortDescriptors.first,
                  let key = descriptor.key.flatMap(Column.init(rawValue:)) else { return { $0.pid < $1.pid } }
            let asc = descriptor.ascending
            // Ties break on pid so equal rows never swap places between refreshes.
            return { [unowned self] a, b in
                let order: ComparisonResult
                switch key {
                case .pid: order = self.compare(a.pid, b.pid)
                case .name: order = a.name.localizedCaseInsensitiveCompare(b.name)
                case .command: order = a.path.localizedCaseInsensitiveCompare(b.path)
                case .threads: order = self.compare(a.threads, b.threads)
                case .user: order = a.user.localizedCaseInsensitiveCompare(b.user)
                case .memory: order = self.compare(a.memory, b.memory)
                case .cpu: order = self.compare(a.cpu, b.cpu)
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
            view.depth = row < depths.count ? depths[row] : 0
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
            (rows, depths) = ordered(rows)
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

        // MARK: Context menu

        private var menuTarget: ProcessRow?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedRow < rows.count else {
                menuTarget = nil
                return
            }
            let p = rows[tableView.clickedRow]
            menuTarget = p
            let header = NSMenuItem(title: "\(p.name) (\(p.pid))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            menu.addItem(item("Copy PID", #selector(copyPID(_:)), enabled: true))
            menu.addItem(item("Copy Path", #selector(copyPath(_:)), enabled: !p.path.isEmpty))
            menu.addItem(item("Reveal in Finder", #selector(revealInFinder(_:)), enabled: !p.path.isEmpty))
            menu.addItem(.separator())
            // Other users' processes can't be signalled without privileges.
            let mine = p.uid == getuid() && p.pid > 1
            menu.addItem(item("Terminate (SIGTERM)", #selector(terminate(_:)), enabled: mine))
            menu.addItem(item("Force Kill (SIGKILL)…", #selector(forceKill(_:)), enabled: mine))
        }

        private func item(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            menuItem.target = self
            menuItem.isEnabled = enabled
            return menuItem
        }

        @objc private func copyPID(_ sender: Any?) {
            guard let p = menuTarget else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(p.pid), forType: .string)
        }

        @objc private func copyPath(_ sender: Any?) {
            guard let p = menuTarget, !p.path.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.path, forType: .string)
        }

        @objc private func revealInFinder(_ sender: Any?) {
            guard let p = menuTarget, !p.path.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
        }

        @objc private func terminate(_ sender: Any?) {
            guard let p = menuTarget else { return }
            report(ProcessSignal.send(SIGTERM, to: p), for: p)
        }

        @objc private func forceKill(_ sender: Any?) {
            guard let p = menuTarget else { return }
            let alert = NSAlert()
            alert.messageText = "Force kill “\(p.name)” (PID \(p.pid))?"
            alert.informativeText = "The process ends immediately. Unsaved work in it will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Force Kill")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            report(ProcessSignal.send(SIGKILL, to: p), for: p)
        }

        private func report(_ result: ProcessSignal.Result, for p: ProcessRow) {
            guard case .failed(let message) = result else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn’t signal “\(p.name)” (PID \(p.pid))"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

/// One process row. AppKit draws the selection highlight as its own view *above* the row's
/// layer, so the text lives in a subview (`RowContentView`), which stays above the highlight.
/// The row itself has no bitmap: the stripe is just its layer's background color.
final class ProcessRowView: NSTableRowView {
    weak var table: NSTableView? {
        didSet { content.table = table }
    }
    var process: ProcessRow? {
        get { content.process }
        set { content.process = newValue }
    }
    var depth: Int {
        get { content.depth }
        set { content.depth = newValue }
    }
    var striped = false {
        didSet { if striped != oldValue { needsDisplay = true } }
    }
    private let content = RowContentView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { content.selected = isSelected && isEmphasized } }
    }
    override var isEmphasized: Bool {
        didSet { if isEmphasized != oldValue { content.selected = isSelected && isEmphasized } }
    }

    /// Inside the window's frosted material AppKit can blend label colors with vibrancy, which
    /// rendered alternate (striped vs. clear) rows at visibly different contrast.
    override var allowsVibrancy: Bool { false }

    override var wantsUpdateLayer: Bool { true }

    /// Translucent stripes (instead of NSTableView's opaque alternating colors) so the
    /// window's material shows through.
    override func updateLayer() {
        var color: CGColor?
        if striped {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.labelColor.withAlphaComponent(0.045).cgColor
            }
        }
        layer?.backgroundColor = color
    }

    func redrawContent() { content.needsDisplay = true }

    override func accessibilityLabel() -> String? {
        guard let p = process else { return nil }
        return "\(p.name), PID \(p.pid), CPU \(String(format: "%.1f", p.cpu)) percent, memory \(formatBytes(p.memory))"
    }
}

/// Draws all columns of one row in a single pass, at the table's column positions.
final class RowContentView: NSView {
    weak var table: NSTableView?
    var process: ProcessRow? {
        didSet { if process != oldValue { needsDisplay = true } }
    }
    var depth = 0 {
        didSet { if depth != oldValue { needsDisplay = true } }
    }
    var selected = false {
        didSet { if selected != oldValue { needsDisplay = true } }
    }
    private static let indentPerLevel: CGFloat = 10
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks select the row

    /// On wide-gamut/EDR displays AppKit gives layer-backed views a 16-bit float backing store;
    /// for ~40 table-wide rows that was ~38 MB. Plain text needs only 8 bits per channel.
    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.contentsFormat = .RGBA8Uint
        return layer
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let process, let table, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let baseline = floor((bounds.height - (Self.font.ascender - Self.font.descender)) / 2 + Self.font.ascender)
        let inset = table.intercellSpacing.width / 2

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // flipped view
        for (index, tableColumn) in table.tableColumns.enumerated() {
            guard let column = ProcessTable.Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            let columnRect = table.rect(ofColumn: index)
            var x = columnRect.minX + inset
            var width = columnRect.width - 2 * inset
            var (text, color) = column.content(process)
            if column == .name, depth > 0 {
                let indent = CGFloat(min(depth - 1, 8)) * Self.indentPerLevel
                x += indent
                width -= indent
                text = "└ " + text
            }
            guard width > 4, x < dirtyRect.maxX, x + width > dirtyRect.minX else { continue }
            let line = TextLineCache.shared.line(text, width: width, column: column, font: Self.font)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let dx = column.alignment == .right ? max(width - lineWidth, 0) : 0
            // On the accent-colored (focused) selection, white text; otherwise the normal colors
            // stay readable on the grey highlight.
            ctx.setFillColor((selected ? NSColor.alternateSelectedControlTextColor : color).cgColor)
            ctx.textPosition = CGPoint(x: x + dx, y: baseline)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
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
