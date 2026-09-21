import AppKit
import SwiftUI

enum DisplayMode: String, CaseIterable {
    case island, menuBar, sidebar
    var title: String { switch self { case .island: return "灵动岛模式"; case .menuBar: return "菜单栏模式"; case .sidebar: return "侧边栏模式" } }
    static func restored(_ saved: String?, majorVersion: Int) -> Self {
        saved.flatMap(Self.init(rawValue:)) ?? (majorVersion >= 27 ? .menuBar : .island)
    }
}

enum OverviewLayout {
    static let width: CGFloat = 320
    static func height(windowCount: Int, hasNotice: Bool = false, availableHeight: CGFloat) -> CGFloat {
        min(max(160, availableHeight - 40), 86 + CGFloat(max(1, windowCount)) * 50 + (hasNotice ? 48 : 0))
    }
}

enum MenuBarArtwork {
    // A small quota meter. Template rendering follows the system menu-bar appearance.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (x, height) in [(3.0, 5.0), (7.5, 9.0), (12.0, 13.0)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 2.5, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

extension AppDelegate: NSPopoverDelegate {
    func loadDisplayMode(from defaults: UserDefaults = .standard) {
        displayMode = .restored(defaults.string(forKey: "displayMode"), majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    func setDisplayMode(_ mode: DisplayMode) {
        activeMenu?.cancelTracking()
        closeOverview(); sidebar?.hide()
        overviewModel.sidebarMode = mode == .sidebar
        hoverWork?.cancel(); hoverWork = nil; collapseWork?.cancel()
        idleTimer?.invalidate(); idleTimer = nil; idle.active = false
        quotaView.expanded = false; panel.orderOut(nil)
        displayMode = mode
        if !demo && !testMode { UserDefaults.standard.set(mode.rawValue, forKey: "displayMode") }
        updateRecoveryItem(); updateView(); rest(); scheduleRotation()
    }
    @objc func selectDisplayMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        setDisplayMode(mode)
    }
    func appendDisplayModeItems(to menu: NSMenu) {
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue
            item.state = mode == displayMode ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
    }
    func updateMenuBarPresentation() {
        guard displayMode == .menuBar else {
            closeOverview()
            if let item = quotaStatusItem { NSStatusBar.system.removeStatusItem(item); quotaStatusItem = nil }
            return
        }
        panel?.orderOut(nil)
        if quotaStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: 74)
            item.autosaveName = "NotchQuota.Quota"
            item.button?.target = self; item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            quotaStatusItem = item
        }
        guard let button = quotaStatusItem?.button else { return }
        if temporarilyHidden || visibleTargets.isEmpty {
            closeOverview()
            quotaStatusItem?.length = NSStatusItem.squareLength
            button.image = NSImage(systemSymbolName: temporarilyHidden ? "eye.slash" : "slider.horizontal.3", accessibilityDescription: "NotchQuota 设置")
            button.title = ""; button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = temporarilyHidden ? "NotchQuota · 点击立即显示" : "NotchQuota · 选择显示的账号"
        } else {
            quotaStatusItem?.length = 74
            button.image = MenuBarArtwork.icon
            button.imagePosition = .imageLeading
            let value = states[target]?.snapshot?.remaining
            let text = value.map { "\(Int($0.rounded()))%" } ?? "—"
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: QuotaTint.color(value)])
            button.toolTip = "\(displayTitle(target)) · \(text) · 点击查看账号详情"
        }
        button.setAccessibilityLabel(button.toolTip)
        if overviewPopover?.isShown == true { updateOverview() }
    }
    @objc func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp || visibleTargets.isEmpty {
            showStatusSettings(); return
        }
        if temporarilyHidden { restoreTemporaryVisibility(); return }
        if overviewPopover?.isShown == true { closeOverview() }
        else { showOverview() }
    }
    func updateOverview() {
        overviewModel.now = Date()
        overviewModel.total = visibleTargets.count
        overviewModel.position = (visibleTargets.firstIndex(of: target) ?? 0) + 1
        overviewModel.accounts = visibleTargets.filter { $0 == target }.map { candidate in
            let custom = accountAliases[candidate.id].flatMap { $0.isEmpty ? nil : $0 }
            return OverviewAccount(id: candidate.id, title: custom ?? candidate.title,
                subtitle: accountNames[candidate.id] ?? (candidate.provider == .antigravity ? "账号信息读取中" : ""),
                image: accountAvatars[candidate.id] ?? candidate.provider.icon, state: states[candidate] ?? DisplayState())
        }
        if displayMode == .menuBar { resizeOverview() }
    }
    func resizeOverview() {
        let state = states[target] ?? DisplayState()
        let available = quotaStatusItem?.button?.window?.screen?.visibleFrame.height ?? 700
        overviewPopover?.contentSize = NSSize(width: OverviewLayout.width, height: OverviewLayout.height(
            windowCount: state.snapshot?.windows.count ?? 0,
            hasNotice: state.error != nil || state.stale, availableHeight: available))
    }
    func showOverview() {
        guard displayMode == .menuBar, !temporarilyHidden, let button = quotaStatusItem?.button else { return }
        updateOverview()
        if overviewPopover == nil {
            let popover = NSPopover(); popover.behavior = .transient; popover.delegate = self
            overviewModel.next = { [weak self] in
                guard let self, self.visibleTargets.count > 1 else { return }
                self.next()
            }
            overviewModel.refresh = { [weak self] in self?.manualRefresh() }
            overviewModel.settings = { [weak self] in self?.showStatusSettings() }
            popover.contentViewController = NSHostingController(rootView: QuotaOverview(model: overviewModel))
            overviewPopover = popover
        }
        resizeOverview()
        overviewPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        overviewTimer?.invalidate()
        overviewTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in if self?.overviewPopover?.isShown == true { self?.updateOverview() } }
        }
        overviewTimer?.tolerance = 5
    }
    func closeOverview() {
        overviewTimer?.invalidate(); overviewTimer = nil
        overviewPopover?.close()
    }
    func popoverWillClose(_ notification: Notification) {
        overviewTimer?.invalidate(); overviewTimer = nil
    }
    func popoverDidClose(_ notification: Notification) {
        overviewTimer?.invalidate(); overviewTimer = nil
    }
    func showStatusSettings() {
        closeOverview()
        guard let button = quotaStatusItem?.button else { return }
        let menu = makeMenu(); activeMenu = menu
        // A native status-item menu stays anchored even inside the system overflow area.
        quotaStatusItem?.menu = menu
        button.performClick(nil)
        quotaStatusItem?.menu = nil; activeMenu = nil
    }
}
