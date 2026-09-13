import AppKit
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NotchPanel!
    var quotaView: QuotaView!
    var target: QuotaTarget = .codex
    var provider: Provider { get { target.provider } set { target = .standard(newValue) } }
    var visibleTargets: [QuotaTarget] = []
    var installed: [Provider] { visibleTargets.map(\.provider) }
    var instances: [AntigravityInstance] = []
    var manualInstances: [AntigravityInstance] = []
    var enabledInstances: Set<String> = []
    var accountBindings: [String: String] = [:]
    var accountNames: [String: String] = [:]
    var accountAliases: [String: String] = [:]
    var accountAvatars: [String: NSImage] = [:]
    var avatarHashes: [String: Int] = [:]
    var blockedAccounts: Set<String> = []
    var instanceReaders: [String: QuotaReader] = [:]
    var accountGenerations: [String: Int] = [:]
    var refreshJobs: [String: Task<Void, Never>] = [:]
    var refreshCycle: Task<Void, Never>?
    var discoveryJob: Task<Void, Never>?
    let instanceDiscovery = AntigravityDiscovery()
    let avatarLoader = AccountAvatars()
    var recoveryItem: NSStatusItem?

    var detectedApps: [Provider] = []
    var excludedProviders: Set<Provider> = []
    var automaticRotation = true
    var suppressMotion = false
    var smokeInstalled: [Provider]?
    var motionDuration: TimeInterval {
        suppressMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled ? 0 : 0.20
    }
    var states: [QuotaTarget: DisplayState] = [:]
    var lastAttempt: [QuotaTarget: Date] = [:]
    let reader = QuotaReader()
    let appUpdates = AppUpdates()
    var idle = IdleState()
    var idleTimer: Timer?
    var refreshTimer: Timer?
    var rotationTimer: Timer?
    var hiddenUntil: Date?
    var hideTimer: Timer?
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
    let animationTestMode = CommandLine.arguments.contains("--animation-test")
    var testMode: Bool { animationTestMode || CommandLine.arguments.contains("--ui-smoke") }
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
        quotaView.onSwitch = { [weak self] in if self?.testMode == false { self?.next() } }
        quotaView.onExpand = { [weak self] in if self?.testMode == false { self?.toggleExpanded() } }
        quotaView.onActivity = { [weak self] in if self?.testMode == false { self?.activity() } }
        quotaView.onLeave = { [weak self] in if self?.testMode == false { self?.leave() } }
        quotaView.onContextMenu = { [weak self] event in if self?.testMode == false { self?.menu(event) } }
        quotaView.onUpdate = { [weak self] in self?.openUpdates() }
        appUpdates.onChange = { [weak self] version in
            self?.quotaView.updateVersion = version
            self?.quotaView.update()
        }
        if !demo && !testMode { appUpdates.start() }
        if !demo && !testMode {
            excludedProviders = Set((UserDefaults.standard.stringArray(forKey: "excludedProviders") ?? []).compactMap(Provider.init(rawValue:)))
            automaticRotation = UserDefaults.standard.object(forKey: "automaticRotation") as? Bool ?? true
        }
        if !demo && !testMode { loadAccountPreferences(); loadTemporaryVisibility() }
        updateScreen()
        if demo || testMode { loadDemo() }
        discoverInstalled(); updateView(); show()
        scheduleIdle(); scheduleHideDeadline()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshAll() } }
        refreshTimer?.tolerance = 15
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if self?.testMode == true { return event }
            if event.type == .keyDown && event.keyCode == 53 { self?.rest() }
            else { self?.activity() }
            return event
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.updateScreen() } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSuspended = true; self?.scheduleRotation() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSuspended = false; self?.reconcileTemporaryHide(); self?.updateScreen(); self?.refreshAll(); self?.scheduleRotation() }
            })
        }
        refreshAll()
        if !demo && !testMode { scanInstances() }
        if animationTestMode { runAnimationTest() }
        else if testMode { runUISmoke() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func loadDemo() {
        for (p, values) in [(Provider.codex, [82.0, 91]), (.claude, [36.0, 64]), (.antigravity, [12.0, 75, 63, 88])] {
            states[.standard(p)] = DisplayState(snapshot: Snapshot(windows: values.enumerated().map { i, value in
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
        let rows = min(6, states[target]?.snapshot?.windows.count ?? 0)
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
        let candidates = testMode ? (smokeInstalled ?? Provider.allCases) : demo ? Provider.allCases : Provider.allCases.filter { Installation.app($0.title) != nil }
        detectedApps = candidates
        var selected = candidates.filter { !excludedProviders.contains($0) && !blockedAccounts.contains($0.rawValue) }.map(QuotaTarget.standard)
        selected += instances.filter { enabledInstances.contains($0.id) && !blockedAccounts.contains($0.id) && $0.supported }.map { QuotaTarget(provider: .antigravity, instance: $0) }
        let old = visibleTargets
        visibleTargets = selected
        updateRecoveryItem()
        guard selected != old else {
            if selected.isEmpty { idle.active = false }
            return
        }
        for removed in old where !selected.contains(removed) { invalidateAccount(removed) }
        scheduleRotation()
        if !selected.contains(target), let first = selected.first { target = first }
        if selected.isEmpty || !idle.active { rest() }
        updateView()
    }
    func updateView(animated: Bool = false) {
        quotaView.provider = provider
        quotaView.nextProviderTitle = nextTarget().map(displayTitle)
        quotaView.accountTitle = provider == .antigravity && (target.instance != nil || visibleTargets.filter { $0.provider == .antigravity }.count > 1) ? accountLabel(target) : nil
        if quotaView.accountTitle == nil { quotaView.accountImage = nil }
        else {
            let number = target.instance.flatMap { item in instances.firstIndex(where: { $0.id == item.id }) }.map { String($0 + 2) } ?? "1"
            quotaView.accountImage = accountAvatars[target.id] ?? AvatarImage.placeholder(number)
        }
        quotaView.state = states[target] ?? DisplayState()
        resize(animated: animated)
    }
    func activity() {
        guard !temporarilyHidden, !installed.isEmpty else { return }
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
        guard !temporarilyHidden, !installed.isEmpty else { return }
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
        guard !temporarilyHidden, !installed.isEmpty else {
            panel.orderOut(nil); return
        }
        updateView(animated: true)
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func scheduleIdle() {
        guard !temporarilyHidden, idle.active, !installed.isEmpty else { return }
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
    /// One low-frequency timer; automatic rotation only displays cached readings.
    func scheduleRotation() {
        rotationTimer?.invalidate(); rotationTimer = nil
        guard !temporarilyHidden, automaticRotation, installed.count > 1, !refreshSuspended else { return }
        rotationTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in if self?.testMode == false { self?.rotateAutomatically() } }
        }
        rotationTimer?.tolerance = 1
        if let rotationTimer { RunLoop.main.add(rotationTimer, forMode: .common) }
    }
    func rotateAutomatically() {
        guard !temporarilyHidden, automaticRotation, !refreshSuspended, !idle.active, !quotaView.expanded, activeMenu == nil else { return }
        switchProvider()
    }
    func next() {
        switchProvider()
        scheduleRotation()
        refresh(target)
    }
    func switchProvider() {
        guard let next = nextTarget() else { return }
        if panel.isVisible && motionDuration > 0 {
            let transition = CATransition()
            transition.type = .fade; transition.duration = 0.38
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            quotaView.layer?.add(transition, forKey: "providerSwitch")
        }
        target = next
        updateView(animated: true)
    }
    func toggleExpanded() {
        hoverWork?.cancel(); hoverWork = nil
        quotaView.expanded.toggle()
        suppressHoverUntilExit = !quotaView.expanded
        resize(animated: true)
    }
    func refreshAll() {
        guard !refreshSuspended else { return }
        discoverInstalled()
        refreshCycle?.cancel()
        let targets = visibleTargets
        refreshCycle = Task { @MainActor [weak self] in
            for (index, candidate) in targets.enumerated() {
                if index > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                guard !Task.isCancelled, let self, !self.refreshSuspended else { return }
                self.refresh(candidate)
            }
        }
    }
    func refresh(_ candidate: QuotaTarget) {
        guard !refreshSuspended, visibleTargets.contains(candidate), !demo, !testMode, states[candidate]?.loading != true else { return }
        if let last = lastAttempt[candidate], Date().timeIntervalSince(last) < 30 { return }
        lastAttempt[candidate] = Date()
        var state = states[candidate] ?? DisplayState(); state.loading = true; states[candidate] = state
        if candidate == target { updateView(animated: true) }
        let generation = accountGenerations[candidate.id, default: 0]
        let accountReader: QuotaReader
        if let instance = candidate.instance {
            if instanceReaders[candidate.id] == nil { instanceReaders[candidate.id] = QuotaReader(googleInstance: instance) }
            accountReader = instanceReaders[candidate.id]!
        } else { accountReader = reader }
        refreshJobs[candidate.id] = Task { @MainActor [weak self] in
            do {
                let snapshot = try await accountReader.fetch(candidate.provider, expectedGoogleSubject: self?.accountBindings[candidate.id])
                let identity = candidate.provider == .antigravity ? await accountReader.accountIdentity() : nil
                guard let self, !Task.isCancelled, self.visibleTargets.contains(candidate), self.accountGenerations[candidate.id, default: 0] == generation else { return }
                if let identity {
                    if let expected = self.accountBindings[candidate.id], expected != identity.subject {
                        self.blockedAccounts.insert(candidate.id)
                        self.states[candidate] = DisplayState(error: "账号已变化，请在菜单重新勾选确认")
                        self.accountNames[candidate.id] = nil; self.accountAvatars[candidate.id] = nil
                        self.saveAccountPreferences(); self.discoverInstalled(); return
                    }
                    self.accountBindings[candidate.id] = identity.subject
                    self.accountNames[candidate.id] = identity.displayName
                    self.saveAccountPreferences()
                }
                self.states[candidate] = DisplayState(snapshot: snapshot)
                if candidate == self.target { self.updateView(animated: true) }
                if let identity { await self.updateAccountAvatar(identity, for: candidate, generation: generation) }
            } catch {
                guard let self, !Task.isCancelled, self.accountGenerations[candidate.id, default: 0] == generation else { return }
                if case QuotaError.accountChanged = error {
                    self.blockedAccounts.insert(candidate.id)
                    self.states[candidate] = DisplayState(error: self.readableError(error))
                    self.accountNames[candidate.id] = nil; self.accountAvatars[candidate.id] = nil
                    self.saveAccountPreferences(); self.discoverInstalled(); return
                }
                if case QuotaError.identityUnverified = error {
                    self.states[candidate] = DisplayState(); self.accountNames[candidate.id] = nil; self.accountAvatars[candidate.id] = nil
                }
                var failed = self.states[candidate] ?? DisplayState(); failed.loading = false; failed.error = self.readableError(error); self.states[candidate] = failed
                if candidate == self.target { self.updateView(animated: true) }
                if candidate.provider == .antigravity, let identity = await accountReader.accountIdentity(),
                   self.accountBindings[candidate.id] == nil || self.accountBindings[candidate.id] == identity.subject {
                    guard !Task.isCancelled, self.visibleTargets.contains(candidate), self.accountGenerations[candidate.id, default: 0] == generation else { return }
                    self.accountBindings[candidate.id] = identity.subject
                    self.accountNames[candidate.id] = identity.displayName
                    self.saveAccountPreferences()
                    if candidate == self.target { self.updateView() }
                    await self.updateAccountAvatar(identity, for: candidate, generation: generation)
                }
            }
        }
    }
    func updateAccountAvatar(_ identity: AccountIdentity, for candidate: QuotaTarget, generation: Int) async {
        guard let data = await avatarLoader.data(for: identity.picture), !Task.isCancelled,
              visibleTargets.contains(candidate), accountGenerations[candidate.id, default: 0] == generation,
              accountBindings[candidate.id] == identity.subject, !blockedAccounts.contains(candidate.id) else { return }
        if accountAvatars[candidate.id] == nil || avatarHashes[candidate.id] != data.hashValue {
            guard let image = AvatarImage.make(data) else { return }
            accountAvatars[candidate.id] = image; avatarHashes[candidate.id] = data.hashValue
        }
        if candidate == target { updateView() }
    }
    func readableError(_ error: Error) -> String {
        if let error = error as? QuotaError { return error.localizedDescription }
        if let error = error as? URLError {
            return error.code == .notConnectedToInternet ? "网络未连接" : "网络请求失败，请检查系统代理"
        }
        return "暂时无法读取额度"
    }
    func menu(_ event: NSEvent) {
        hoverWork?.cancel(); hoverWork = nil; collapseWork?.cancel(); idleTimer?.invalidate(); idleTimer = nil
        quotaView.expanded = false; resize()
        let menu = makeMenu(); activeMenu = menu
        // Present below the panel rather than at the notch/top-edge click location.
        menu.popUp(positioning: nil, at: NSPoint(x: panel.frame.minX + 12, y: panel.frame.minY - 6), in: nil)
        activeMenu = nil
        if !temporarilyHidden { idle.interact(at: ProcessInfo.processInfo.systemUptime); scheduleIdle() }
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.minimumWidth = 210
        appendTemporaryVisibilityMenu(to: menu)
        let refresh = NSMenuItem(title: "刷新额度", action: #selector(manualRefresh), keyEquivalent: "r"); refresh.target = self; menu.addItem(refresh)
        let hide = NSMenuItem(title: "收起详情", action: #selector(manualRest), keyEquivalent: "h"); hide.target = self; hide.isEnabled = !temporarilyHidden
        if quotaView?.expanded == true && !temporarilyHidden { menu.addItem(hide) }
        menu.addItem(.separator())
        let rotation = NSMenuItem(title: "自动轮换（每分钟）", action: #selector(toggleAutomaticRotation), keyEquivalent: "")
        rotation.target = self; rotation.state = automaticRotation ? .on : .off; menu.addItem(rotation)
        let choices = NSMenu()
        choices.autoenablesItems = false; choices.minimumWidth = 240
        for candidate in detectedApps {
            let item = NSMenuItem(title: displayTitle(.standard(candidate)), action: #selector(toggleProviderVisibility(_:)), keyEquivalent: "")
            item.image = accountAvatars[candidate.rawValue] ?? candidate.icon
            item.target = self; item.representedObject = candidate.rawValue
            item.state = visibleTargets.contains(.standard(candidate)) ? .on : .off
            if blockedAccounts.contains(candidate.rawValue) { item.title += " · 账号已变化，重新勾选确认" }
            choices.addItem(item)
        }
        let selection = NSMenuItem(title: "显示的应用", action: nil, keyEquivalent: "")
        selection.submenu = choices; menu.addItem(selection)
        appendAccountMenu(to: menu, inlineAccounts: choices)
        let settingsMenu = NSMenu(); settingsMenu.autoenablesItems = false; settingsMenu.minimumWidth = 240
        let loginState = demo || testMode ? LoginItemState.disabled : LaunchAtLogin.state
        let login = NSMenuItem(title: loginState.title, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self; login.state = loginState.checkmark
        settingsMenu.addItem(login)
        if loginState == .requiresApproval {
            let settings = NSMenuItem(title: "在系统设置中允许自动启动…", action: #selector(openLoginSettings), keyEquivalent: "")
            settings.target = self; settingsMenu.addItem(settings)
        }
        settingsMenu.addItem(.separator())
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let versionInfo = NSMenuItem(title: "当前版本：\(currentVersion)", action: nil, keyEquivalent: "")
        versionInfo.isEnabled = false; settingsMenu.addItem(versionInfo)
        let updates = NSMenuItem(title: appUpdates.menuTitle, action: #selector(openUpdates), keyEquivalent: ""); updates.target = self; updates.isEnabled = !demo && !testMode && appUpdates.canCheck; settingsMenu.addItem(updates)
        let automatic = NSMenuItem(title: "自动检查新版本（每天）", action: #selector(toggleUpdateChecks), keyEquivalent: "")
        automatic.target = self; automatic.state = appUpdates.automaticallyChecks ? .on : .off
        automatic.isEnabled = !demo && !testMode
        settingsMenu.addItem(automatic)
        let help = NSMenuItem(title: "使用说明 / 反馈问题…", action: #selector(openHelp), keyEquivalent: ""); help.target = self; settingsMenu.addItem(help)
        let settingsRoot = NSMenuItem(title: "设置与更新", action: nil, keyEquivalent: "")
        settingsRoot.submenu = settingsMenu; menu.addItem(settingsRoot)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 NotchQuota", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        return menu
    }
    func saveProviderPreferences() {
        guard !demo && !testMode else { return }
        UserDefaults.standard.set(excludedProviders.map(\.rawValue).sorted(), forKey: "excludedProviders")
        UserDefaults.standard.set(automaticRotation, forKey: "automaticRotation")
    }
    @objc func toggleAutomaticRotation() {
        automaticRotation.toggle(); saveProviderPreferences(); scheduleRotation()
    }
    @objc func toggleProviderVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let candidate = Provider(rawValue: raw) else { return }
        if blockedAccounts.remove(candidate.rawValue) != nil {
            accountBindings[candidate.rawValue] = nil; excludedProviders.remove(candidate); saveAccountPreferences()
        } else if !excludedProviders.insert(candidate).inserted { excludedProviders.remove(candidate) }
        saveProviderPreferences(); discoverInstalled(); scheduleRotation(); refresh(.standard(candidate))
    }
    @objc func manualRefresh() { activity(); refreshAll() }
    @objc func manualRest() { rest() }
    @objc func openUpdates() {
        guard !demo, !testMode else { return }
        activeMenu?.cancelTracking()
        appUpdates.check()
    }
    @objc func toggleUpdateChecks() { guard !demo, !testMode else { return }; appUpdates.toggleAutomaticChecks() }
    @objc func openHelp() { NSWorkspace.shared.open(URL(string: "https://github.com/bcblr1993/NotchQuota#readme")!) }
    @objc func toggleLaunchAtLogin() {
        guard !demo, !testMode else { return }
        do {
            try LaunchAtLogin.setEnabled(LaunchAtLogin.state.shouldEnableOnToggle)
            if LaunchAtLogin.state == .requiresApproval { LaunchAtLogin.openSettings() }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法更改开机自动启动"
            alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
    @objc func openLoginSettings() { LaunchAtLogin.openSettings() }
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
        quotaView.expanded = false; provider = .codex; resize(); suppressMotion = false; show()
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
            for _ in 0..<20 where idleTimer != nil { await settle(0.1) }
            check(panel.isVisible && !idle.active && !quotaView.expanded && provider == .codex, "idle keeps default compact quota")
            check(idleTimer == nil, "idle timer stops")
            let compactFrame = panel.frame
            quotaView.updateVersion = "0.1.8"; quotaView.update(); capture("update-available")
            check(panel.frame == compactFrame && !quotaView.expanded, "update reminder keeps compact size")
            check(!appUpdates.canCheck, "smoke never starts real updater")
            quotaView.updateVersion = nil; quotaView.update()
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
            rest(); await settle(); check(provider == .claude, "rest preserves current provider")
            check(abs((rotationTimer?.timeInterval ?? 0) - 60) < 0.01, "rotation interval is 60 seconds")
            let attempts = lastAttempt
            rotateAutomatically(); await settle(); check(provider == .antigravity, "automatic rotation advances")
            capture("rotation-antigravity")
            rotateAutomatically(); await settle(); check(provider == .codex, "automatic rotation wraps")
            check(lastAttempt == attempts && !idle.active && !quotaView.expanded, "rotation does not query or expand")
            refreshSuspended = true; rotateAutomatically(); check(provider == .codex, "sleep pauses rotation")
            refreshSuspended = false
            activity(); rotateAutomatically(); check(provider == .codex, "interaction pauses rotation")
            rest()
            excludedProviders = [.claude, .antigravity]; discoverInstalled(); rest()
            rotateAutomatically(); next(); await settle()
            check(installed == [.codex] && provider == .codex && rotationTimer == nil, "manual Codex selection stops rotation")
            excludedProviders = []; discoverInstalled(); rest()
            automaticRotation = false; scheduleRotation(); let fixed = provider; rotateAutomatically()
            check(provider == fixed && rotationTimer == nil, "rotation preference disables timer")
            automaticRotation = true; scheduleRotation()
            check(rotationTimer != nil, "rotation preference restores timer")
            let extra = AntigravityInstance(appPath: "/Fixtures/Extra.app", credentialPath: "/Fixtures/extra.json", name: "Antigravity · 工作")
            let extraTarget = QuotaTarget(provider: .antigravity, instance: extra)
            instances = [extra]; discoverInstalled()
            check(!visibleTargets.contains(extraTarget), "new instance defaults hidden")
            enabledInstances = [extra.id]; discoverInstalled()
            check(visibleTargets.count == 4, "extra instance joins rotation independently")
            target = .antigravity; rest(); rotateAutomatically()
            check(target == extraTarget, "rotation reaches extra instance")
            states[extraTarget] = DisplayState(snapshot: Snapshot(windows: [.init(id: "extra", label: "每周", remaining: 73)]))
            updateView(); quotaView.expanded = true; resize(); capture("multi-instance")
            check(states[.antigravity]?.snapshot?.remaining != states[extraTarget]?.snapshot?.remaining, "instances keep separate quota caches")
            excludedProviders = Set(Provider.allCases); discoverInstalled()
            check(visibleTargets == [extraTarget] && rotationTimer == nil, "only extra instance can stay visible")
            enabledInstances = []; discoverInstalled()
            check(visibleTargets.isEmpty && !panel.isVisible && recoveryItem?.menu?.items.contains(where: { $0.submenu?.items.contains(where: { $0.action == #selector(toggleProviderVisibility(_:)) }) == true }) == true, "hide all leaves settings recovery")
            excludedProviders = []; instances = []; discoverInstalled()
            check(recoveryItem == nil, "restoring account removes recovery icon")
            target = .codex; rest()
            smokeInstalled = [.claude]; discoverInstalled(); next(); await settle()
            check(provider == .claude && rotationTimer == nil && quotaView.nextProviderTitle == nil && panel.isVisible, "single app stays selected")
            capture("claude-only")
            smokeInstalled = []; discoverInstalled(); await settle(); show(); await settle()
            check(!panel.isVisible && !idle.active && idleTimer == nil, "no apps stays empty")
            smokeInstalled = [.antigravity]; refreshSuspended = true; refreshAll()
            check(installed.isEmpty && !panel.isVisible, "sleep suspends refresh work")
            refreshSuspended = false; refreshAll(); await settle()
            check(panel.isVisible && provider == .antigravity && !quotaView.expanded && !idle.active, "new install shows compact fallback")
            check(NSApp.windows.filter { $0.isVisible }.count == 1, "only one window and no outline")
            smokeInstalled = Provider.allCases; discoverInstalled(); rest()
            let mainMenu = makeMenu()
            let durationMenu = mainMenu.items.first { $0.title == "临时隐藏" }?.submenu
            check(mainMenu.items.count <= 10 && mainMenu.size.height < (screen?.visibleFrame.height ?? 600) - topHeight - 24, "main menu fits below notch without scrolling")
            check((durationMenu?.size.width ?? 0) >= 150 && durationMenu?.items.map(\.title) == ["15 分钟", "1 小时", "3 小时", "5 小时"], "duration submenu reserves full label width")
            print("Menu size: \(mainMenu.size), duration submenu: \(durationMenu?.size ?? .zero)")
            let savedTargets = visibleTargets, savedTarget = target
            let start = Date()
            hideTemporarily(for: 900, now: start)
            check(!panel.isVisible && rotationTimer == nil && idleTimer == nil && hideTimer != nil, "temporary hide stops panel and interaction timers")
            check(recoveryItem?.menu?.items.contains(where: { $0.action == #selector(restoreTemporaryVisibility) }) == true, "temporary hide has immediate restore menu")
            show(); rest(); activity(); rotateAutomatically(); refreshAll(); updateScreen(); await settle()
            check(!panel.isVisible && target == savedTarget && !idle.active, "background refresh and interaction cannot reveal hidden panel")
            hideTemporarily(for: 3600, now: start)
            reconcileTemporaryHide(now: start.addingTimeInterval(900))
            check(temporarilyHidden && !panel.isVisible, "new duration replaces previous deadline")
            reconcileTemporaryHide(now: start.addingTimeInterval(3600))
            check(panel.isVisible && !temporarilyHidden && hideTimer == nil && recoveryItem == nil && rotationTimer != nil && visibleTargets == savedTargets, "wake after deadline restores without changing selection")
            hideTemporarily(for: 18000); restoreTemporaryVisibility()
            check(panel.isVisible && hiddenUntil == nil && !quotaView.expanded, "immediate restore returns compact view")
            hideTemporarily(for: 0.1); await settle(1.4)
            check(!temporarilyHidden && panel.isVisible && hideTimer == nil, "deadline timer restores automatically")
            hideTemporarily(for: 900); excludedProviders = Set(Provider.allCases); discoverInstalled(); restoreTemporaryVisibility()
            check(!panel.isVisible && recoveryItem != nil && visibleTargets.isEmpty, "restore respects all accounts disabled")
            excludedProviders = []; discoverInstalled(); rest(); capture("temporary-hide-restored")
            print("Compact: \(cameraWidth + (cameraWidth > 0 ? 94 : 100)) × \(topHeight)")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }
}

if CommandLine.arguments.contains("--verify-accounts") {
    Task {
        let primary = await MainActor.run { Installation.app("Antigravity") }
        let extras = await AntigravityDiscovery().discover(primary: primary, manual: [])
        let targets = [QuotaTarget.antigravity] + extras.filter(\.supported).map { QuotaTarget(provider: .antigravity, instance: $0) }
        var subjects = Set<String>(), failures = 0
        for target in targets {
            let reader = QuotaReader(googleInstance: target.instance, verifyRefresh: CommandLine.arguments.contains("--force-refresh"))
            do {
                let snapshot = try await reader.fetch(.antigravity)
                guard let identity = await reader.accountIdentity() else { throw QuotaError.identityUnverified }
                subjects.insert(identity.subject)
                let data = await AccountAvatars().data(for: identity.picture)
                let decoded = await MainActor.run { data.flatMap(AvatarImage.make) != nil }
                print("Account \(target.title): quota=PASS windows=\(snapshot.windows.count) identity=PASS avatar=\(decoded ? "PASS" : "FALLBACK")")
            } catch { failures += 1; print("Account \(target.title): FAIL \((error as? QuotaError)?.localizedDescription ?? "网络或本地读取失败")") }
        }
        print("Verified \(targets.count - failures)/\(targets.count); distinct identities=\(subjects.count)")
        fflush(stdout); exit(failures == 0 ? 0 : 1)
    }
    dispatchMain()
} else if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    MainActor.assumeIsolated {
        let operation = CommandLine.arguments.dropFirst(index + 1).first ?? "status"
        do {
            switch operation {
            case "status": break
            case "enable": try LaunchAtLogin.setEnabled(true)
            case "disable": try LaunchAtLogin.setEnabled(false)
            default: throw QuotaError.message("支持的操作为 status、enable、disable")
            }
            print("Login item: \(LaunchAtLogin.state.label)")
        } catch { print("Login item: ERROR \(error.localizedDescription)"); exit(1) }
    }
} else if CommandLine.arguments.contains("--diagnose") {
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
