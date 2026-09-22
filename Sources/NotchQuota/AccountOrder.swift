import AppKit

enum AccountOrder {
    static func apply(_ targets: [QuotaTarget], saved: [String]) -> [QuotaTarget] {
        var ranks: [String: Int] = [:]
        for id in saved where ranks[id] == nil { ranks[id] = ranks.count }
        return targets.enumerated().sorted {
            let a = ranks[$0.element.id] ?? Int.max, b = ranks[$1.element.id] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    // Replace visible slots only, retaining the relative positions of temporarily hidden accounts.
    static func merging(_ visibleIDs: [String], into saved: [String]) -> [String] {
        let visible = Set(visibleIDs)
        var queue = visibleIDs.makeIterator(), result: [String] = [], seen = Set<String>()
        for id in saved where seen.insert(id).inserted {
            if visible.contains(id) { if let next = queue.next() { result.append(next) } }
            else { result.append(id) }
        }
        result.append(contentsOf: queue)
        return result
    }
}

@MainActor final class AccountOrderEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let view: NSView
    let table = NSTableView()
    var accounts: [QuotaTarget]
    let label: (QuotaTarget) -> String
    let up = NSButton(title: "上移", target: nil, action: nil)
    let down = NSButton(title: "下移", target: nil, action: nil)
    private let dragType = NSPasteboard.PasteboardType("io.github.notchquota.account-order")
    private var dialog: NSWindow?

    init(accounts: [QuotaTarget], label: @escaping (QuotaTarget) -> String) {
        self.accounts = accounts; self.label = label
        let height = CGFloat(min(max(accounts.count, 2), 8)) * 54 + 164
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: height))
        super.init()
        let title = NSTextField(labelWithString: "账号显示顺序")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let help = NSTextField(labelWithString: "拖动账号排序，或选中后使用上移、下移。")
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor
        let count = NSTextField(labelWithString: "\(accounts.count) 个账号")
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("account"))
        column.width = 404; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 52; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .fullWidth; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.setAccessibilityLabel("账号顺序，可拖动调整")
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = table
        for (index, button) in [up, down].enumerated() {
            button.bezelStyle = .rounded; button.target = self
            button.action = index == 0 ? #selector(moveUp) : #selector(moveDown)
            button.keyEquivalent = index == 0 ? "\u{F700}" : "\u{F701}"
            button.keyEquivalentModifierMask = [.option]
            button.toolTip = index == 0 ? "上移（⌥↑）" : "下移（⌥↓）"
        }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(saveEditing))
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let footnote = NSTextField(labelWithString: "用于侧边栏与账号轮换；未显示的账号保留原位置。")
        footnote.font = .systemFont(ofSize: 11); footnote.textColor = .secondaryLabelColor
        for child in [title, help, count, scroll, up, down, cancel, save, footnote] {
            child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            count.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            count.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            help.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            help.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: up.topAnchor, constant: -12),
            up.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            down.leadingAnchor.constraint(equalTo: up.trailingAnchor, constant: 6),
            down.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            save.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            save.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            cancel.centerYAnchor.constraint(equalTo: up.centerYAnchor),
            save.widthAnchor.constraint(equalToConstant: 72), cancel.widthAnchor.constraint(equalToConstant: 72),
            footnote.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footnote.topAnchor.constraint(equalTo: up.bottomAnchor, constant: 8),
            footnote.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        table.reloadData()
        if !accounts.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateButtons()
    }
    func run() -> Bool {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "调整账号顺序"; window.contentView = view
        window.isReleasedWhenClosed = false; window.delegate = self; dialog = window
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            if window.frame.height > frame.height - 32 {
                window.setContentSize(NSSize(width: view.frame.width, height: max(280, frame.height - 60)))
            }
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(table)
        let result = NSApp.runModal(for: window)
        window.orderOut(nil); dialog = nil
        return result == .OK
    }
    @objc private func cancelEditing() { NSApp.stopModal(withCode: .cancel) }
    @objc private func saveEditing() { NSApp.stopModal(withCode: .OK) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelEditing(); return false }
    func numberOfRows(in tableView: NSTableView) -> Int { accounts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let target = accounts[row], full = label(accounts[row])
        let cell = NSTableCellView()
        let number = NSTextField(labelWithString: "\(row + 1)")
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        number.textColor = .secondaryLabelColor; number.alignment = .center
        let icon = NSImageView(image: target.provider.icon)
        let name = NSTextField(labelWithString: target.title)
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingTail
        let secondary = full.hasPrefix(target.title + " · ") ? String(full.dropFirst(target.title.count + 3)) : (full == target.title ? "" : full)
        let detail = NSTextField(labelWithString: secondary)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")!)
        grip.contentTintColor = .tertiaryLabelColor
        for child in [number, icon, name, detail, grip] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), number.widthAnchor.constraint(equalToConstant: 22), number.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6), icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), name.topAnchor.constraint(equalTo: cell.topAnchor, constant: secondary.isEmpty ? 18 : 8), name.trailingAnchor.constraint(equalTo: grip.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3), detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            grip.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12), grip.widthAnchor.constraint(equalToConstant: 12), grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = full; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        up.isEnabled = table.selectedRow > 0
        down.isEnabled = table.selectedRow >= 0 && table.selectedRow < accounts.count - 1
    }
    @objc private func moveUp() { move(-1) }
    @objc private func moveDown() { move(1) }
    private func move(_ offset: Int) { reorder(from: table.selectedRow, to: table.selectedRow + offset) }
    func reorder(from: Int, to: Int) {
        guard accounts.indices.contains(from), accounts.indices.contains(to), from != to else { return }
        let account = accounts.remove(at: from); accounts.insert(account, at: to)
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: to), byExtendingSelection: false)
        table.scrollRowToVisible(to); updateButtons()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem(); item.setString(String(row), forType: dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, row >= 0, row <= accounts.count else { return [] }
        table.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: dragType), let source = Int(value),
              accounts.indices.contains(source), row >= 0, row <= accounts.count else { return false }
        reorder(from: source, to: row > source ? row - 1 : row); return true
    }
}

extension AppDelegate {
    @objc func editAccountOrder() {
        activeMenu?.cancelTracking(); sidebar?.cancelIdle(); sidebar?.dismiss(animated: false)
        defer { sidebar?.scheduleIdleCollapse() }
        guard visibleTargets.count > 1 else { return }
        let editor = AccountOrderEditor(accounts: visibleTargets) { [weak self] in self?.displayTitle($0) ?? $0.title }
        guard editor.run() else { return }
        accountOrder = AccountOrder.merging(editor.accounts.map(\.id), into: accountOrder)
        saveAccountPreferences(); discoverInstalled()
    }
}
