import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var quotaView: QuotaView!
    var provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .codex
    var states: [Provider: DisplayState] = [:]
    var lastAttempt: [Provider: Date] = [:]
    let reader = QuotaReader()
    var idle = IdleState()
    var idleTimer: Timer?
    var refreshTimer: Timer?
    var mouseMonitor: Any?
    var localMonitor: Any?
    var displayObserver: NSObjectProtocol?
    var wakeObserver: NSObjectProtocol?
    var hoverWork: DispatchWorkItem?
    var collapseWork: DispatchWorkItem?
    var activeMenu: NSMenu?
    var hiddenPointerInside = false
    var screen: NSScreen?
    var topHeight: CGFloat = 30
    var cameraWidth: CGFloat = 0
    var demo = CommandLine.arguments.contains("--demo")
    let testMode = CommandLine.arguments.contains("--ui-smoke")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !demo && !testMode {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.bcblr1993.NotchQuota")
            if others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        }
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false; panel.title = "NotchQuota"
        quotaView = QuotaView(frame: .zero); panel.contentView = quotaView
        quotaView.onSwitch = { [weak self] in self?.next() }
        quotaView.onExpand = { [weak self] in self?.toggleExpanded() }
        quotaView.onActivity = { [weak self] in self?.activity() }
        quotaView.onLeave = { [weak self] in self?.leave() }
        quotaView.onContextMenu = { [weak self] event in self?.menu(event) }
        updateScreen()
        if demo || testMode { loadDemo() }
        updateView(); show()
        scheduleIdle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshAll() } }
        refreshTimer?.tolerance = 15
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.mouseMoved() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { self?.hide() }
            else { self?.mouseMoved() }
            return event
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.updateScreen() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.updateScreen(); self?.refreshAll() } }
        refreshAll()
        if testMode { runUISmoke() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func loadDemo() {
        for (p, values) in [(Provider.codex, [82.0, 91]), (.claude, [36.0, 64]), (.antigravity, [12.0, 75, 63, 88])] {
            states[p] = DisplayState(snapshot: Snapshot(windows: values.enumerated().map { i, value in
                QuotaWindow(id: "demo-\(i)", label: p == .antigravity ? ["Gemini · 每周", "Gemini · 5 小时", "Claude / GPT · 每周", "Claude / GPT · 5 小时"][i] : (i == 0 ? "5 小时" : "每周"), remaining: value, reset: Date().addingTimeInterval(8400))
            }))
        }
    }
    func updateScreen() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        topHeight = max(28, screen.safeAreaInsets.top)
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 { cameraWidth = max(0, right.minX - left.maxX) }
        else { cameraWidth = 0 }
        quotaView?.cameraWidth = cameraWidth; quotaView?.topHeight = topHeight
        resize()
    }
    func resize() {
        guard let screen, panel != nil else { return }
        let compact = cameraWidth > 0 ? cameraWidth + 94 : 100
        let expanded = quotaView.expanded
        let width = expanded ? max(276, compact) : compact
        let rows = min(6, states[provider]?.snapshot?.windows.count ?? 0)
        let detailHeight: CGFloat = rows == 0 ? 105 : CGFloat(12 + 39 + rows * 32 + 29)
        let height = topHeight + (expanded ? detailHeight : 0)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        quotaView.frame = NSRect(origin: .zero, size: panel.frame.size)
        quotaView.update()
    }
    func updateView() { quotaView.provider = provider; quotaView.state = states[provider] ?? DisplayState(); resize() }
    func activity() {
        collapseWork?.cancel()
        idle.interact(at: ProcessInfo.processInfo.systemUptime)
        scheduleIdle()
        guard !quotaView.expanded, hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.hoverWork = nil
            if self.idle.visible && self.panel.frame.contains(NSEvent.mouseLocation) { self.quotaView.expanded = true; self.resize() }
        }
        hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }
    func leave() {
        hoverWork?.cancel(); hoverWork = nil
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.quotaView.expanded = false; self?.resize() }
        collapseWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func show() {
        idle.interact(at: ProcessInfo.processInfo.systemUptime)
        scheduleIdle()
        panel.alphaValue = 1; panel.orderFrontRegardless()
    }
    func hide() {
        hoverWork?.cancel(); hoverWork = nil; collapseWork?.cancel()
        idle.visible = false
        activeMenu?.cancelTracking()
        idleTimer?.invalidate(); idleTimer = nil
        hiddenPointerInside = revealRect.contains(NSEvent.mouseLocation)
        quotaView.expanded = false
        panel.orderOut(nil); resize()
    }
    var revealRect: NSRect {
        guard let screen else { return .zero }
        let width = max(110, cameraWidth + 94)
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - topHeight - 3, width: width, height: topHeight + 3)
    }
    func mouseMoved(at point: NSPoint? = nil) {
        let position = point ?? NSEvent.mouseLocation
        if !idle.visible {
            let inside = revealRect.contains(position)
            if inside && !hiddenPointerInside { show(); activity() }
            hiddenPointerInside = inside
        } else if panel.frame.contains(position) { activity() }
    }
    func scheduleIdle() {
        let remaining = max(0.05, IdleState.delay - (ProcessInfo.processInfo.systemUptime - idle.lastInteraction))
        if let timer = idleTimer, timer.isValid { timer.fireDate = Date().addingTimeInterval(remaining); return }
        idleTimer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        if let idleTimer { RunLoop.main.add(idleTimer, forMode: .common) }
        idleTimer?.tolerance = 0.1
    }
    func tick() {
        if idle.tick(at: ProcessInfo.processInfo.systemUptime) { hide() }
        else if idle.visible { scheduleIdle() }
    }
    func next() {
        provider = provider.next
        if !demo && !testMode { UserDefaults.standard.set(provider.rawValue, forKey: "provider") }
        updateView(); refresh(provider)
    }
    func toggleExpanded() {
        hoverWork?.cancel(); hoverWork = nil
        quotaView.expanded.toggle(); resize()
    }
    func refreshAll() { for provider in Provider.allCases { refresh(provider) } }
    func refresh(_ p: Provider) {
        guard !demo, !testMode, states[p]?.loading != true else { return }
        if let last = lastAttempt[p], Date().timeIntervalSince(last) < 30 { return }
        lastAttempt[p] = Date(); var state = states[p] ?? DisplayState(); state.loading = true; states[p] = state
        if p == provider { updateView() }
        Task {
            do { let snapshot = try await reader.fetch(p); states[p] = DisplayState(snapshot: snapshot) }
            catch { var failed = states[p] ?? DisplayState(); failed.loading = false; failed.error = readableError(error); states[p] = failed }
            if p == provider { updateView() }
        }
    }
    func readableError(_ error: Error) -> String {
        if let error = error as? QuotaError { return error.localizedDescription }
        if let error = error as? URLError {
            return error.code == .notConnectedToInternet ? "网络未连接" : "网络请求失败，请检查系统代理"
        }
        return "暂时无法读取额度"
    }
    func menu(_ event: NSEvent) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "刷新额度", action: #selector(manualRefresh), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
        let hide = NSMenuItem(title: "立即隐藏", action: #selector(manualHide), keyEquivalent: "h"); hide.target = self; menu.addItem(hide)
        menu.addItem(.separator())
        let info = NSMenuItem(title: "无操作 15 秒后隐藏", action: nil, keyEquivalent: ""); info.isEnabled = false; menu.addItem(info)
        menu.addItem(.separator())
        let updates = NSMenuItem(title: "下载更新…", action: #selector(openUpdates), keyEquivalent: ""); updates.target = self; menu.addItem(updates)
        let help = NSMenuItem(title: "使用说明 / 反馈问题…", action: #selector(openHelp), keyEquivalent: ""); help.target = self; menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NotchQuota", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        activeMenu = menu
        NSMenu.popUpContextMenu(menu, with: event, for: quotaView)
        activeMenu = nil
    }
    @objc func manualRefresh() { activity(); refreshAll() }
    @objc func manualHide() { hide() }
    @objc func openUpdates() { NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/NotchQuota/releases/latest")!) }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/NotchQuota#readme")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func runUISmoke() {
        let base = ProcessInfo.processInfo.environment["NOTCHQUOTA_SMOKE_DIR"] ?? FileManager.default.temporaryDirectory.path
        func capture(_ name: String) {
            guard let rep = quotaView.bitmapImageRepForCachingDisplay(in: quotaView.bounds) else { return }
            quotaView.cacheDisplay(in: quotaView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: base).appendingPathComponent(name + ".png")) }
        }
        provider = .codex; updateView(); capture("compact")
        quotaView.expanded = true; resize(); capture("codex")
        next(); capture("claude"); next(); capture("antigravity")
        quotaView.expanded = false; resize(); show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.8) { [self] in
            let passed = !panel.isVisible && !idle.visible
            print("UI idle 15s: \(passed ? "PASS" : "FAIL")")
            mouseMoved(at: NSPoint(x: revealRect.minX - 100, y: revealRect.minY - 100))
            mouseMoved(at: NSPoint(x: revealRect.midX, y: revealRect.midY))
            print("UI hotzone reappear: \(panel.isVisible ? "PASS" : "FAIL")")
            print("Compact: \(cameraWidth + (cameraWidth > 0 ? 94 : 100)) × \(topHeight)")
            NSApp.terminate(nil)
        }
    }
}

if CommandLine.arguments.contains("--diagnose") {
    let reader = QuotaReader()
    let selected = CommandLine.arguments.dropFirst(2).compactMap(Provider.init(rawValue:))
    let targets = selected.isEmpty ? Provider.allCases : selected
    Task {
        for p in targets {
            do {
                let snapshot = try await reader.fetch(p)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let encoded = try encoder.encode(snapshot)
                print("\(p.rawValue): \(String(decoding: encoded, as: UTF8.self))")
            } catch { print("\(p.rawValue): ERROR \((error as? QuotaError)?.localizedDescription ?? "网络或本地读取失败")") }
        }
        exit(0)
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
