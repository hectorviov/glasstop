import AppKit
import SwiftUI

struct ProcessPanel: View {
    @Environment(Sampler.self) private var sampler
    @Environment(AppState.self) private var appState
    @AppStorage("processFilter") private var filter = ""
    @AppStorage("processOnlyMine") private var onlyMine = false
    @AppStorage("processHideIdle") private var hideIdle = false
    @AppStorage("processTree") private var tree = false
    @AppStorage("processCPULazy") private var cpuLazy = false
    /// Pinned processes, in pin order. Not persisted: a pid means nothing after a relaunch.
    @State private var pins: [PinKey] = []
    private static let maxPins = 8

    private static let myUID = getuid()

    private var rows: [ProcessRow] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty || onlyMine || hideIdle else { return sampler.processes }
        return sampler.processes.filter {
            (!onlyMine || $0.uid == Self.myUID)
                && (!hideIdle || $0.cpu > 0 || $0.memory > 0 || $0.gpu > 0)
                && (f.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(f)
                    || $0.path.localizedCaseInsensitiveContains(f)
                    || $0.user.localizedCaseInsensitiveContains(f)
                    || String($0.pid).hasPrefix(f))
        }
    }

    var body: some View {
        let rows = self.rows
        Panel(title: "PROC", tint: .blue, trailing: "\(rows.count)") {
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
            SearchField(text: $filter, placeholder: "Filter (⌘F)", focusRequest: appState.focusFilterRequest)
                .frame(minWidth: 90, idealWidth: 200, maxWidth: 200)   // gives way first when narrow
                // The search bezel is translucent by design; a solid backing keeps the material
                // (and whatever is behind the window) from showing through.
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .padding(1))
            Toggle("Lazy", isOn: $cpuLazy)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .fixedSize()
                .help("CPU% sort like btop's \"cpu lazy\": by average CPU over each process's lifetime, so the order doesn't jump every refresh; processes using a lot of CPU right now are still pulled to the top")
        } content: {
            ProcessTable(rows: rows, tree: tree, cpuLazy: cpuLazy, pinned: pinnedEntries,
                         onTogglePin: togglePin, onUnpin: { key in pins.removeAll { $0 == key } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Live rows for the pinned processes (nil once a process has exited). Ignores the filter
    /// and view options: a pinned process stays visible.
    private var pinnedEntries: [PinnedEntry] {
        let pids = Set(pins.map(\.pid))
        var live: [PinKey: ProcessRow] = [:]
        for row in sampler.processes where pids.contains(row.pid) { live[PinKey(row)] = row }
        return pins.map { PinnedEntry(key: $0, row: live[$0]) }
    }

    private func togglePin(_ row: ProcessRow) {
        let key = PinKey(row)
        if let index = pins.firstIndex(of: key) {
            pins.remove(at: index)
        } else if pins.count < Self.maxPins {
            pins.append(key)
        } else {
            NSSound.beep()
        }
    }
}

// MARK: Pinned processes

/// A pinned process: pid + start time, so a reused pid is never mistaken for it.
struct PinKey: Hashable {
    let pid: pid_t
    let start: UInt64
    init(_ row: ProcessRow) { pid = row.pid; start = row.start }
}

struct PinnedEntry: Equatable {
    let key: PinKey
    let row: ProcessRow?        // nil: the process has exited
}

/// The "PINNED" strip under the table's header: a label, one row per pinned process drawn
/// with the table's column geometry (the rows don't live in the table, so sorting and
/// scrolling never move them), each with a red unpin button at the end, and a divider. An
/// exited process stays, dimmed, with its last values until it's unpinned.
final class PinnedRowsView: NSView {
    static let rowPitch: CGFloat = 19             // table row height 17 + intercell spacing 2
    private static let labelHeight: CGFloat = 15
    private static let dividerHeight: CGFloat = 5
    /// Text keeps clear of the button by this much plus the button itself.
    private static let buttonSize: CGFloat = 14
    private static let buttonGap: CGFloat = 8
    private static let buttonInset: CGFloat = 5   // from the row's end

    static func height(rows: Int) -> CGFloat {
        rows == 0 ? 0 : labelHeight + CGFloat(rows) * rowPitch + dividerHeight
    }

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "PINNED")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private var rows: [ProcessRowView] = []
    private var buttons: [NSButton] = []
    private var keys: [PinKey] = []
    private var lastSeen: [PinKey: ProcessRow] = [:]
    private var onUnpin: ((PinKey) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ entries: [PinnedEntry], table: NSTableView?, onUnpin: @escaping (PinKey) -> Void) {
        self.onUnpin = onUnpin
        while rows.count < entries.count { addRow() }
        while rows.count > entries.count {
            rows.removeLast().removeFromSuperview()
            buttons.removeLast().removeFromSuperview()
        }
        keys = entries.map(\.key)
        for (i, entry) in entries.enumerated() {
            if let row = entry.row { lastSeen[entry.key] = row }
            let view = rows[i]
            view.table = table
            view.striped = i % 2 == 1
            view.exited = entry.row == nil
            view.process = entry.row ?? lastSeen[entry.key]
            buttons[i].toolTip = entry.row == nil ? "Exited · Unpin" : "Unpin"
        }
        lastSeen = lastSeen.filter { keys.contains($0.key) }
        needsLayout = true
    }

    func redrawAll() { rows.forEach { $0.redrawContent() } }

    private func addRow() {
        let row = ProcessRowView(identifier: NSUserInterfaceItemIdentifier("pinnedRow"))
        row.trailingReserve = Self.buttonInset + Self.buttonSize + Self.buttonGap
        addSubview(row)
        rows.append(row)

        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Unpin")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(unpin(_:)))
        button.isBordered = false
        button.contentTintColor = .systemRed
        button.tag = buttons.count
        addSubview(button)                      // above the row views
        buttons.append(button)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 6, y: 2, width: 80, height: Self.labelHeight - 2)
        for (i, row) in rows.enumerated() {
            let y = Self.labelHeight + CGFloat(i) * Self.rowPitch
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowPitch)
            buttons[i].frame = NSRect(x: bounds.width - Self.buttonInset - Self.buttonSize,
                                      y: y + (Self.rowPitch - Self.buttonSize) / 2,
                                      width: Self.buttonSize, height: Self.buttonSize)
        }
    }

    /// Divider between the pinned rows and the live list.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: bounds.height - 3, width: bounds.width, height: 1).fill()
    }

    @objc private func unpin(_ sender: NSButton) {
        guard sender.tag < keys.count else { return }
        onUnpin?(keys[sender.tag])
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
    var cpuLazy = false
    var pinned: [PinnedEntry] = []
    var onTogglePin: ((ProcessRow) -> Void)?
    var onUnpin: ((PinKey) -> Void)?

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
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        context.coordinator.observeColumnWidths(of: table)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = OverlayScrollView()
        let pinnedView = PinnedRowsView()
        scroll.topAccessory = pinnedView
        context.coordinator.pinnedView = pinnedView
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
        context.coordinator.cpuLazy = cpuLazy
        context.coordinator.pinned = Set(pinned.map(\.key))
        context.coordinator.onTogglePin = onTogglePin
        if let scroll = nsView as? OverlayScrollView, let pinnedView = context.coordinator.pinnedView {
            pinnedView.update(pinned, table: context.coordinator.tableView) { key in onUnpin?(key) }
            scroll.topAccessoryHeight = PinnedRowsView.height(rows: pinned.count)
        }
        context.coordinator.update(rows)
    }

    enum Column: String, CaseIterable {
        case pid, name, command, threads, user, memory, cpu, gpu

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
            case .gpu: return "GPU%"
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
            case .gpu: return 60
            }
        }
        /// CPU% / GPU% keep room for the title plus the sort arrow.
        var minWidth: CGFloat { self == .cpu || self == .gpu ? 60 : min(width, 34) }
        var flexible: Bool { self == .name || self == .command }
        var alignment: NSTextAlignment {
            switch self {
            case .pid, .threads, .memory, .cpu, .gpu: return .right
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
            case .gpu:
                // Readable for every process, so other users' rows show it too (WindowServer…).
                let color = r.gpu >= 1 ? Palette.loadNS((min(r.gpu, 100) / 5).rounded() * 5)
                                       : (r.accessible ? Self.secondary : dim)
                return (String(format: "%.1f", r.gpu), color)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var tableView: NSTableView?
        private var rows: [ProcessRow] = []
        private var depths: [Int] = []          // tree depth per row (all 0 in flat mode)
        var tree = false
        var cpuLazy = false
        var pinned: Set<PinKey> = []
        var onTogglePin: ((ProcessRow) -> Void)?
        weak var pinnedView: PinnedRowsView?
        private var resizeObserver: NSObjectProtocol?
        private var widthObservers: [NSKeyValueObservation] = []

        /// Rows draw their own columns, so they must redraw whenever a column's width changes.
        /// `columnDidResize` only arrives at the start and end of a drag; KVO on `width` fires
        /// for every step, so the text follows the divider live.
        func observeColumnWidths(of table: NSTableView) {
            widthObservers = table.tableColumns.map { column in
                column.observe(\.width, options: [.new]) { [weak self] _, _ in
                    self?.refreshVisibleRows(forceRedraw: true)   // width changes happen on main
                }
            }
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

        /// Programmatic tables don't reliably shrink their columns with the scroll view, so the
        /// flexible columns (Name, Command) are fitted to the visible width on every resize,
        /// keeping their current proportions. When the table gets too narrow for Name and Command
        /// to stay readable, columns drop out in `hideOrder` (like btop) and return when it widens.
        func observeResizes(of clip: NSClipView) {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak clip] _ in
                guard let clip else { return }
                MainActor.assumeIsolated { self?.fitColumns(to: clip.bounds.width) }
            }
        }

        private static let hideOrder: [Column] = [.command, .user, .threads, .pid]
        private static let readableWidth: [Column: CGFloat] = [.name: 130, .command: 170]

        private func fitColumns(to available: CGFloat) {
            guard let tableView, available > 0 else { return }
            let all = tableView.tableColumns
            let cell = tableView.intercellSpacing.width
            func kind(_ c: NSTableColumn) -> Column? { Column(rawValue: c.identifier.rawValue) }
            // Width needed with a set of columns hidden: fixed columns at their current width,
            // flexible ones at their readable minimum.
            func needed(hiding hidden: Set<Column>) -> CGFloat {
                all.reduce(0) { sum, c in
                    guard let k = kind(c), !hidden.contains(k) else { return sum }
                    return sum + cell + (k.flexible ? Self.readableWidth[k] ?? c.minWidth : c.width)
                }
            }
            var hidden = Set<Column>()
            for column in Self.hideOrder where needed(hiding: hidden) > available { hidden.insert(column) }
            var visibilityChanged = false
            for c in all {
                let hide = kind(c).map(hidden.contains) ?? false
                if c.isHidden != hide { c.isHidden = hide; visibilityChanged = true }
            }
            defer { if visibilityChanged { refreshVisibleRows(forceRedraw: true) } }

            let columns = all.filter { !$0.isHidden }
            let spacing = cell * CGFloat(columns.count)
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
            if forceRedraw { pinnedView?.redrawAll() }   // pinned rows share the column geometry
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
            guard tree else {
                var sorted = input.sorted(by: less)
                if isLazyCPUSort, tableView?.sortDescriptors.first?.ascending == false { bumpBusy(&sorted) }
                return (sorted, Array(repeating: 0, count: sorted.count))
            }

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

        private var isLazyCPUSort: Bool { cpuLazy && tableView?.sortDescriptors.first?.key == Column.cpu.rawValue }

        /// btop's "cpu lazy" (btop_shared.cpp, proc_sorter; Apache-2.0, see NOTICE): after
        /// sorting by lifetime CPU, processes that are busy *now* move to the front. The
        /// threshold is 30%, or the busiest of the first six rows if that's higher (10% if none
        /// of them passes 30%); rows already at the front above 30% stay put; at most 11 rows
        /// move per refresh.
        private func bumpBusy(_ rows: inout [ProcessRow]) {
            var maxCPU = 10.0, target = 30.0, offset = 0, moved = 0
            for i in rows.indices {
                if i <= 5, rows[i].cpu > maxCPU {
                    maxCPU = rows[i].cpu
                } else if i == 6 {
                    target = maxCPU > 30 ? maxCPU : 10
                }
                if i == offset, rows[i].cpu > 30 {
                    offset += 1
                } else if rows[i].cpu > target {
                    let row = rows.remove(at: i)
                    rows.insert(row, at: offset)
                    moved += 1
                    if moved > 10 { break }
                }
            }
        }

        private func comparator() -> (ProcessRow, ProcessRow) -> Bool {
            guard let descriptor = tableView?.sortDescriptors.first,
                  let key = descriptor.key.flatMap(Column.init(rawValue:)) else { return { $0.pid < $1.pid } }
            let asc = descriptor.ascending
            let lazy = isLazyCPUSort
            let now = Date().timeIntervalSince1970
            /// Average % of one core since the process started (btop's `cpu_c`).
            func lifetimeCPU(_ r: ProcessRow) -> Double { r.cpuTime / max(now - Double(r.start), 1) * 100 }
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
                case .cpu: order = lazy ? self.compare(lifetimeCPU(a), lifetimeCPU(b)) : self.compare(a.cpu, b.cpu)
                case .gpu: order = self.compare(a.gpu, b.gpu)
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

        /// Double-click pins the row's process (or unpins it if it's already pinned).
        @objc func doubleClicked(_ sender: Any?) {
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedRow < rows.count else { return }
            onTogglePin?(rows[tableView.clickedRow])
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
            menu.addItem(item(pinned.contains(PinKey(p)) ? "Unpin" : "Pin", #selector(togglePin(_:)),
                              enabled: onTogglePin != nil))
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

        @objc private func togglePin(_ sender: Any?) {
            guard let p = menuTarget else { return }
            onTogglePin?(p)
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

/// Always uses overlay scrollers: with legacy ("always show") scrollers the table gets a
/// separate gutter and a darker corner box above it, next to the header. Overlay scrollers
/// float over the rows and the header spans the full width.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// A strip between the table's header and its rows (the pinned processes). It isn't part
    /// of the scrolled content: the clip view and scroller give up its height.
    var topAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let topAccessory { addSubview(topAccessory) }
            tile()
        }
    }
    var topAccessoryHeight: CGFloat = 0 {
        didSet { if topAccessoryHeight != oldValue { tile() } }
    }
    private var overridingInsets = false

    /// Back to the standard layout once the strip is gone: the clip view runs under the header
    /// again with a top inset for it. Only setting `automaticallyAdjustsContentInsets` back
    /// left the inset at 0 until the next tile, so the first row sat behind the header.
    private func restoreHeaderInset() {
        guard overridingInsets else { return }
        overridingInsets = false
        contentView.automaticallyAdjustsContentInsets = true
        super.tile()
        let headerHeight = (documentView as? NSTableView)?.headerView?.frame.height ?? 0
        if contentView.contentInsets.top < headerHeight {
            contentView.contentInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
        }
        shiftScroll(by: -contentView.contentInsets.top)   // keep the same rows in view
    }

    /// Moves the scroll position by `dy` (the clip view is flipped: positive is down) when the
    /// top inset changes, so the rows that were visible stay put.
    private func shiftScroll(by dy: CGFloat) {
        var bounds = contentView.bounds
        bounds.origin.y += dy
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    override func tile() {
        super.tile()
        guard let topAccessory else { return }
        let height = topAccessoryHeight
        topAccessory.isHidden = height == 0
        guard height > 0 else {
            restoreHeaderInset()
            return
        }
        // Normally the clip view runs under the header with a top inset for it, so rows can
        // scroll beneath it. With the strip in between that inset would leave a gap (and rows
        // scrolling behind the strip): the clip starts below the strip with no inset instead.
        let header = (documentView as? NSTableView)?.headerView?.superview?.frame ?? .zero
        var clip = contentView.frame
        if isFlipped {
            topAccessory.frame = NSRect(x: clip.minX, y: header.maxY, width: clip.width, height: height)
            clip.origin.y = header.maxY + height
            clip.size.height = max(bounds.height - clip.minY, 0)
        } else {
            topAccessory.frame = NSRect(x: clip.minX, y: header.minY - height, width: clip.width, height: height)
            clip.size.height = max(header.minY - height - clip.minY, 0)
        }
        contentView.frame = clip
        contentView.automaticallyAdjustsContentInsets = false
        overridingInsets = true
        if contentView.contentInsets.top != 0 {
            contentView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            shiftScroll(by: 0)           // just re-clamp: the old top position maps onto the new one
        }
        if let scroller = verticalScroller, !scroller.isHidden {
            var frame = scroller.frame
            frame.size.height = clip.height
            frame.origin.y = clip.minY
            scroller.frame = frame
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
    /// Space kept clear at the row's end (pinned rows put their unpin button there).
    var trailingReserve: CGFloat {
        get { content.trailingReserve }
        set { content.trailingReserve = newValue }
    }
    /// The process has exited (pinned rows keep showing its last values, dimmed).
    var exited: Bool {
        get { content.dimmed }
        set { content.dimmed = newValue }
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
        return "\(p.name), PID \(p.pid), CPU \(String(format: "%.1f", p.cpu)) percent, GPU \(String(format: "%.1f", p.gpu)) percent, memory \(formatBytes(p.memory))"
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
    var trailingReserve: CGFloat = 0 {
        didSet { if trailingReserve != oldValue { needsDisplay = true } }
    }
    var dimmed = false {
        didSet { if dimmed != oldValue { needsDisplay = true } }
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
        if dimmed { ctx.setAlpha(0.4) }
        for (index, tableColumn) in table.tableColumns.enumerated() {
            guard !tableColumn.isHidden,
                  let column = ProcessTable.Column(rawValue: tableColumn.identifier.rawValue) else { continue }
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
            let limit = bounds.width - trailingReserve   // last column(s) give way to it
            if x + width > limit { width = limit - x }
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

/// Search field drawn like in a normal window. Inside the frosted material AppKit renders it
/// with vibrancy, which made the box translucent.
final class OpaqueSearchField: NSSearchField {
    override var allowsVibrancy: Bool { false }
}

/// The system search field (magnifier, clear button while there's text, Esc clears), bound to
/// a SwiftUI string. `focusRequest` changes (⌘F) make it first responder.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = OpaqueSearchField()
        field.placeholderString = placeholder
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))   // also fires for the clear button
        field.stringValue = text
        context.coordinator.lastFocusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest = 0

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            update(field.stringValue)
        }

        @objc func changed(_ sender: NSSearchField) { update(sender.stringValue) }

        /// ↓ in the filter moves into the table (selecting the first row if none is), like
        /// Spotlight and Finder's search.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.moveDown(_:)),
                  let window = control.window,
                  let table = window.contentView?.firstDescendant(of: NSTableView.self),
                  table.numberOfRows > 0 else { return false }
            window.makeFirstResponder(table)
            if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            table.scrollRowToVisible(max(table.selectedRow, 0))
            return true
        }

        private func update(_ value: String) {
            if text.wrappedValue != value { text.wrappedValue = value }
        }
    }
}
