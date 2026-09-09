import AppKit
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var quotaView: QuotaView!
    var provider: Provider = .codex
    var installed: [Provider] = []
    var suppressMotion = false
    var smokeInstalled: [Provider]?
    var motionDuration: TimeInterval {
        suppressMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled ? 0 : 0.20
    }
    var states: [Provider: DisplayState] = [:]
    var lastAttempt: [Provider: Date] = [:]
    let reader = QuotaReader()
    var idle = IdleState()
    var idleTimer: Timer?
    var refreshTimer: Timer?
    var localMonitor: Any?
    var displayObserver: NSObjectProtocol?
    var powerObservers: [NSObjectProtocol] = []
    var refreshSuspended = false
    var suppressHoverUntilExit = false
    var hoverWork: DispatchWorkItem?
    var collapseWork: DispatchWorkItem?
    var activeMenu: NSMenu?
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
        quotaView.onActivity = { [weak self] in if self?.testMode == false { self?.activity() } }
        quotaView.onLeave = { [weak self] in if self?.testMode == false { self?.leave() } }
        quotaView.onContextMenu = { [weak self] event in self?.menu(event) }
        updateScreen()
        if demo || testMode { loadDemo() }
        discoverInstalled(); updateView(); show()
        scheduleIdle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshAll() } }
        refreshTimer?.tolerance = 15
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 { self?.rest() }
            else { self?.activity() }
            return event
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.updateScreen() } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSuspended = true }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSuspended = false; self?.updateScreen(); self?.refreshAll() }
            })
        }
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
    func resize(animated: Bool = false) {
        guard let screen, panel != nil else { return }
        let compact = cameraWidth > 0 ? cameraWidth + 94 : 100
        let expanded = quotaView.expanded
        let width = expanded ? max(276, compact) : compact
        let rows = min(6, states[provider]?.snapshot?.windows.count ?? 0)
        let detailHeight: CGFloat = rows == 0 ? 105 : CGFloat(12 + 39 + rows * 32 + 29)
        let height = topHeight + (expanded ? detailHeight : 0)
        let target = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        quotaView.update()
        guard panel.frame != target else { return }
        if animated && panel.isVisible && motionDuration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = motionDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else { panel.setFrame(target, display: panel.isVisible) }
    }
    func discoverInstalled() {
        let detected = testMode ? (smokeInstalled ?? Provider.allCases) : demo ? Provider.allCases : Provider.allCases.filter { Installation.app($0.title) != nil }
        guard detected != installed else {
            if detected.isEmpty { idle.active = false }
            return
        }
        installed = detected
        if let selected = ProviderSelection(installed: installed).selected(preferred: provider) { provider = selected }
        if installed.isEmpty || !idle.active { rest() }
        updateView()
    }
    func updateView(animated: Bool = false) {
        quotaView.provider = provider
        quotaView.nextProviderTitle = installed.count > 1 ? ProviderSelection(installed: installed).next(after: provider)?.title : nil
        quotaView.state = states[provider] ?? DisplayState()
        resize(animated: animated)
    }
    func activity() {
        guard !installed.isEmpty else { return }
        collapseWork?.cancel()
        idle.interact(at: ProcessInfo.processInfo.systemUptime)
        scheduleIdle()
        guard !quotaView.expanded, !suppressHoverUntilExit, hoverWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.hoverWork = nil
            if self.idle.active && self.panel.frame.contains(NSEvent.mouseLocation) { self.quotaView.expanded = true; self.resize(animated: true) }
        }
        hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }
    func leave() {
        suppressHoverUntilExit = false
        hoverWork?.cancel(); hoverWork = nil
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.quotaView.expanded = false; self?.resize(animated: true) }
        collapseWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func show() {
        discoverInstalled()
        guard !installed.isEmpty else { return }
        idle.interact(at: ProcessInfo.processInfo.systemUptime)
        scheduleIdle()
        if !panel.isVisible { panel.alphaValue = 0; resize(); panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
    /// Idle ends the interaction session, but the compact quota stays visible.
    func rest() {
        hoverWork?.cancel(); hoverWork = nil; collapseWork?.cancel()
        idle.active = false
        activeMenu?.cancelTracking()
        idleTimer?.invalidate(); idleTimer = nil
        quotaView.expanded = false
        guard let preferred = ProviderSelection(installed: installed).defaultProvider else {
            panel.orderOut(nil); return
        }
        provider = preferred
        updateView(animated: true)
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func scheduleIdle() {
        guard idle.active, !installed.isEmpty else { return }
        let remaining = max(0.05, IdleState.delay - (ProcessInfo.processInfo.systemUptime - idle.lastInteraction))
        if let timer = idleTimer, timer.isValid { timer.fireDate = Date().addingTimeInterval(remaining); return }
        idleTimer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in Task { @MainActor [weak self] in self?.tick() } }
        if let idleTimer { RunLoop.main.add(idleTimer, forMode: .common) }
        idleTimer?.tolerance = 0.1
    }
    func tick() {
        if idle.tick(at: ProcessInfo.processInfo.systemUptime) { rest() }
        else if idle.active { scheduleIdle() }
    }
    func next() {
        guard installed.count > 1, let next = ProviderSelection(installed: installed).next(after: provider) else { return }
        if panel.isVisible && motionDuration > 0 {
            let transition = CATransition()
            transition.type = .fade; transition.duration = motionDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            quotaView.layer?.add(transition, forKey: "providerSwitch")
        }
        provider = next
        updateView(animated: true); refresh(provider)
    }
    func toggleExpanded() {
        hoverWork?.cancel(); hoverWork = nil
        quotaView.expanded.toggle()
        suppressHoverUntilExit = !quotaView.expanded
        resize(animated: true)
    }
    func refreshAll() {
        guard !refreshSuspended else { return }
        discoverInstalled(); for provider in installed { refresh(provider) }
    }
    func refresh(_ p: Provider) {
        guard !refreshSuspended, installed.contains(p), !demo, !testMode, states[p]?.loading != true else { return }
        if let last = lastAttempt[p], Date().timeIntervalSince(last) < 30 { return }
        lastAttempt[p] = Date(); var state = states[p] ?? DisplayState(); state.loading = true; states[p] = state
        if p == provider { updateView(animated: true) }
        Task {
            do { let snapshot = try await reader.fetch(p); states[p] = DisplayState(snapshot: snapshot) }
            catch { var failed = states[p] ?? DisplayState(); failed.loading = false; failed.error = readableError(error); states[p] = failed }
            if p == provider { updateView(animated: true) }
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
        let hide = NSMenuItem(title: "收起并显示默认额度", action: #selector(manualRest), keyEquivalent: "h"); hide.target = self; menu.addItem(hide)
        menu.addItem(.separator())
        let info = NSMenuItem(title: "无操作 15 秒后显示默认额度", action: nil, keyEquivalent: ""); info.isEnabled = false; menu.addItem(info)
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
    @objc func manualRest() { rest() }
    @objc func openUpdates() { NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/NotchQuota/releases/latest")!) }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/NotchQuota#readme")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func runUISmoke() {
        let base = ProcessInfo.processInfo.environment["NOTCHQUOTA_SMOKE_DIR"] ?? FileManager.default.temporaryDirectory.path
        func capture(_ name: String, view: NSView? = nil) {
            let view = view ?? quotaView!
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: base).appendingPathComponent(name + ".png")) }
        }
        suppressMotion = true
        provider = .codex; updateView(); capture("compact")
        quotaView.expanded = true; resize(); capture("codex")
        next(); capture("claude"); next(); capture("antigravity")
        quotaView.expanded = false; resize(); suppressMotion = false; show()
        Task { @MainActor in
            var failures = 0
            func check(_ condition: Bool, _ name: String) {
                print("UI \(name): \(condition ? "PASS" : "FAIL")")
                if !condition { failures += 1 }
            }
            func settle(_ seconds: Double = 0.35) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            await settle(15.8)
            check(panel.isVisible && !idle.active && !quotaView.expanded && provider == .codex, "idle keeps default compact quota")
            check(idleTimer == nil, "idle timer stops")
            capture("standby-codex")
            let interactionTime = idle.lastInteraction
            states[.codex] = DisplayState(snapshot: Snapshot(windows: [.init(id: "update", label: "每周", remaining: 59)]))
            updateView(); await settle()
            check(quotaView.percentage == "59%" && !idle.active && idle.lastInteraction == interactionTime && !quotaView.expanded, "background update stays compact")
            activity()
            check(idle.active, "compact view remains interactive")
            hoverWork?.cancel(); hoverWork = nil
            toggleExpanded(); await settle(0.08)
            if motionDuration > 0 { check(panel.frame.height > topHeight && panel.frame.height < topHeight + 112, "expansion intermediate frame") }
            await settle(); rest(); await settle()
            check(panel.isVisible && abs(panel.frame.height - topHeight) < 1, "rest collapses without hiding")
            check(abs(panel.frame.maxY - (screen?.frame.maxY ?? 0)) < 1, "top anchor")
            show(); toggleExpanded(); await settle(); toggleExpanded(); await settle(); activity()
            check(!quotaView.expanded && hoverWork == nil, "manual collapse suppresses immediate hover")
            leave(); check(!suppressHoverUntilExit, "pointer exit restores hover")
            collapseWork?.cancel()
            next(); check(provider == .claude, "click switches app")
            rest(); await settle(); check(provider == .codex, "rest resets priority")
            smokeInstalled = [.claude]; discoverInstalled(); next(); await settle()
            check(provider == .claude && quotaView.nextProviderTitle == nil && panel.isVisible, "single app stays selected")
            capture("claude-only")
            smokeInstalled = []; discoverInstalled(); await settle(); show(); await settle()
            check(!panel.isVisible && !idle.active && idleTimer == nil, "no apps stays empty")
            smokeInstalled = [.antigravity]; refreshSuspended = true; refreshAll()
            check(installed.isEmpty && !panel.isVisible, "sleep suspends refresh work")
            refreshSuspended = false; refreshAll(); await settle()
            check(panel.isVisible && provider == .antigravity && !quotaView.expanded && !idle.active, "new install shows compact fallback")
            check(NSApp.windows.filter { $0.isVisible }.count == 1, "only one window and no outline")
            print("Compact: \(cameraWidth + (cameraWidth > 0 ? 94 : 100)) × \(topHeight)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
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
