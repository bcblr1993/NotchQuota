import AppKit

extension AppDelegate {
    static let hideDurations: [(title: String, seconds: TimeInterval)] = [
        ("15 分钟", 15 * 60), ("1 小时", 60 * 60),
        ("3 小时", 3 * 60 * 60), ("5 小时", 5 * 60 * 60)
    ]
    // Keep the panel hidden until the deadline is explicitly reconciled, including after sleep.
    var temporarilyHidden: Bool { hiddenUntil != nil }

    func loadTemporaryVisibility(from defaults: UserDefaults = .standard, now: Date = Date()) {
        hiddenUntil = (defaults.object(forKey: "hiddenUntil") as? Date).flatMap { $0 > now ? $0 : nil }
        if hiddenUntil == nil { defaults.removeObject(forKey: "hiddenUntil") }
    }
    func saveTemporaryVisibility(to defaults: UserDefaults = .standard) {
        guard !demo, !testMode else { return }
        if let hiddenUntil { defaults.set(hiddenUntil, forKey: "hiddenUntil") }
        else { defaults.removeObject(forKey: "hiddenUntil") }
    }
    func scheduleHideDeadline() {
        hideTimer?.invalidate(); hideTimer = nil
        guard let hiddenUntil else { return }
        let timer = Timer(fire: hiddenUntil, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileTemporaryHide() }
        }
        timer.tolerance = 1
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func hideTemporarily(for seconds: TimeInterval, now: Date = Date()) {
        guard seconds > 0 else { return }
        hiddenUntil = now.addingTimeInterval(seconds)
        saveTemporaryVisibility()
        rest(); scheduleRotation(); scheduleHideDeadline(); updateRecoveryItem()
    }
    func reconcileTemporaryHide(now: Date = Date()) {
        guard let hiddenUntil else { return }
        if hiddenUntil <= now { restoreTemporaryVisibility() }
        else { scheduleHideDeadline() }
    }
    @objc func restoreTemporaryVisibility() {
        hiddenUntil = nil
        hideTimer?.invalidate(); hideTimer = nil
        saveTemporaryVisibility()
        discoverInstalled(); updateRecoveryItem(); scheduleRotation(); rest()
        refreshAll()
    }
    @objc func selectHideDuration(_ sender: NSMenuItem) {
        guard Self.hideDurations.contains(where: { Int($0.seconds) == sender.tag }) else { return }
        hideTemporarily(for: TimeInterval(sender.tag))
    }
    func appendTemporaryVisibilityMenu(to menu: NSMenu) {
        if let hiddenUntil {
            let time = DateFormatter.localizedString(from: hiddenUntil, dateStyle: .none, timeStyle: .short)
            let info = NSMenuItem(title: "隐藏至 \(time) · 点击 Dock 可恢复", action: nil, keyEquivalent: "")
            info.isEnabled = false; menu.addItem(info)
            let restore = NSMenuItem(title: "立即显示", action: #selector(restoreTemporaryVisibility), keyEquivalent: "")
            restore.target = self; menu.addItem(restore)
        }
        let choices = NSMenu(); choices.autoenablesItems = false; choices.minimumWidth = 150
        for duration in Self.hideDurations {
            let item = NSMenuItem(title: duration.title, action: #selector(selectHideDuration(_:)), keyEquivalent: "")
            item.target = self; item.tag = Int(duration.seconds); choices.addItem(item)
        }
        let item = NSMenuItem(title: "临时隐藏", action: nil, keyEquivalent: "")
        item.submenu = choices; menu.addItem(item)
    }
}
