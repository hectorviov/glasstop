import AppKit
import SwiftUI

struct ProcessPanel: View {
    @Environment(Sampler.self) private var sampler
    @State private var filter = ""

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
            TextField("filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 200)
        } content: {
            ProcessTable(rows: rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// NSTableView instead of SwiftUI Table: fixed row heights, only visible rows are realized,
/// and no SwiftUI row diffing (which triggered AppKit's "reentrant operation in its
/// NSTableView delegate" warning on every row-count change).
struct ProcessTable: NSViewRepresentable {
    let rows: [ProcessRow]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.rowHeight = 17
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for column in Coordinator.Column.allCases {
            let c = NSTableColumn(identifier: column.identifier)
            c.title = column.title
            c.width = column.width
            c.minWidth = column.minWidth
            c.resizingMask = column.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            c.headerCell.alignment = column.alignment
            c.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.ascendingByDefault)
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: Coordinator.Column.cpu.rawValue, ascending: false)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(rows)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
                case .cpu: return "CPU %"
                }
            }
            var width: CGFloat {
                switch self {
                case .pid: return 50
                case .name: return 140
                case .command: return 140
                case .threads: return 30
                case .user: return 72
                case .memory: return 66
                case .cpu: return 48
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
        }

        weak var tableView: NSTableView?
        private var rows: [ProcessRow] = []
        private var selectedPID: pid_t?
        private var isReloading = false
        private let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

        /// Called every refresh. Rows are positional, so instead of reloadData() (which tears
        /// down and rebuilds every visible cell) only the row count is adjusted and the
        /// visible cells are patched in place.
        func update(_ newRows: [ProcessRow]) {
            guard let tableView else { return }
            let oldCount = rows.count
            rows = sorted(newRows)
            isReloading = true
            if rows.count > oldCount {
                tableView.insertRows(at: IndexSet(oldCount..<rows.count), withAnimation: [])
            } else if rows.count < oldCount {
                tableView.removeRows(at: IndexSet(rows.count..<oldCount), withAnimation: [])
            }
            let visible = tableView.rows(in: tableView.visibleRect)
            for row in visible.location..<min(visible.location + visible.length, rows.count) {
                for (index, tableColumn) in tableView.tableColumns.enumerated() {
                    guard let column = Column(rawValue: tableColumn.identifier.rawValue),
                          let field = tableView.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTextField
                    else { continue }
                    configure(field, column: column, row: rows[row])
                }
            }
            restoreSelection()
            isReloading = false
        }

        private func reload() {
            guard let tableView else { return }
            isReloading = true
            tableView.reloadData()
            restoreSelection()
            isReloading = false
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

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  row < rows.count else { return nil }
            let field = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField)
                ?? makeField(column)
            configure(field, column: column, row: rows[row])
            return field
        }

        /// Only touches the field when something changed: every set triggers a redraw.
        private func configure(_ field: NSTextField, column: Column, row r: ProcessRow) {
            let text: String
            var color: NSColor = .labelColor
            switch column {
            case .pid:
                text = String(r.pid)
                color = .secondaryLabelColor
            case .name:
                text = r.name
            case .command:
                text = r.path
                color = .secondaryLabelColor
            case .threads:
                text = r.accessible ? String(r.threads) : "—"
            case .user:
                text = r.user
                color = .secondaryLabelColor
            case .memory:
                text = r.accessible ? formatBytes(r.memory) : "—"
            case .cpu:
                text = r.accessible ? String(format: "%.1f", r.cpu) : "—"
                // Quantized so tiny load changes don't recolor (and redraw) the cell.
                color = r.accessible && r.cpu >= 1 ? Palette.loadNS((min(r.cpu, 100) / 5).rounded() * 5) : .secondaryLabelColor
            }
            if !r.accessible, column != .name { color = .tertiaryLabelColor }
            if field.stringValue != text { field.stringValue = text }
            if field.textColor != color { field.textColor = color }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            rows = sorted(rows)
            reload()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isReloading, let tableView else { return }
            let i = tableView.selectedRow
            selectedPID = i >= 0 && i < rows.count ? rows[i].pid : nil
        }

        private func makeField(_ column: Column) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.identifier = column.identifier
            field.font = font
            field.alignment = column.alignment
            field.lineBreakMode = column == .command ? .byTruncatingMiddle : .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            return field
        }
    }
}
