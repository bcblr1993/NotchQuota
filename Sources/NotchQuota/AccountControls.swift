import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum AvatarImage {
    static func placeholder(_ number: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.darkGray.setFill(); NSBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (number as NSString).size(withAttributes: attributes)
            (number as NSString).draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2), withAttributes: attributes)
            return true
        }
    }
    static func make(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let input = NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip(); input.draw(in: rect); return true
        }
    }
}

extension AppDelegate {
    func loadAccountPreferences(from defaults: UserDefaults = .standard) {
        enabledInstances = Set(defaults.stringArray(forKey: "enabledInstances") ?? [])
        accountBindings = defaults.dictionary(forKey: "accountBindings") as? [String: String] ?? [:]
        blockedAccounts = Set(defaults.stringArray(forKey: "blockedAccounts") ?? [])
        accountAliases = defaults.dictionary(forKey: "accountAliases") as? [String: String] ?? [:]
        if let data = defaults.data(forKey: "manualInstances"), let saved = try? JSONDecoder().decode([AntigravityInstance].self, from: data) { manualInstances = saved }
    }
    func saveAccountPreferences(to defaults: UserDefaults = .standard) {
        guard !demo, !testMode else { return }
        defaults.set(enabledInstances.sorted(), forKey: "enabledInstances")
        defaults.set(accountBindings, forKey: "accountBindings")
        defaults.set(accountAliases, forKey: "accountAliases")
        defaults.set(blockedAccounts.sorted(), forKey: "blockedAccounts")
        defaults.set(try? JSONEncoder().encode(manualInstances), forKey: "manualInstances")
    }
    func accountLabel(_ candidate: QuotaTarget) -> String {
        if let alias = accountAliases[candidate.id], !alias.isEmpty { return alias }
        return accountNames[candidate.id] ?? candidate.title
    }
    func displayTitle(_ candidate: QuotaTarget) -> String {
        if let alias = accountAliases[candidate.id], !alias.isEmpty { return alias }
        if let name = accountNames[candidate.id], candidate.provider == .antigravity {
            return "\(candidate.title) · \(name)"
        }
        return candidate.title
    }
    func nextTarget() -> QuotaTarget? {
        guard visibleTargets.count > 1 else { return nil }
        guard let index = visibleTargets.firstIndex(of: target) else { return visibleTargets.first }
        return visibleTargets[(index + 1) % visibleTargets.count]
    }
    func invalidateAccount(_ candidate: QuotaTarget) {
        accountGenerations[candidate.id, default: 0] += 1
        refreshJobs[candidate.id]?.cancel(); refreshJobs[candidate.id] = nil
        states[candidate]?.loading = false
        lastAttempt[candidate] = nil
    }
    @objc func scanInstances() {
        guard !demo, !testMode, discoveryJob == nil else { return }
        let primary = Installation.app("Antigravity"), manual = manualInstances
        discoveryJob = Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await self.instanceDiscovery.discover(primary: primary, manual: manual)
            guard !Task.isCancelled else { return }
            let old = self.instances
            self.instances = found
            for instance in old where !found.contains(instance) {
                let candidate = QuotaTarget(provider: .antigravity, instance: instance)
                self.invalidateAccount(candidate); self.instanceReaders[instance.id] = nil
                self.states[candidate] = nil; self.accountAvatars[instance.id] = nil; self.accountNames[instance.id] = nil
            }
            self.discoveryJob = nil
            self.discoverInstalled()
            self.refreshAll()
        }
    }
    func appendAccountMenu(to menu: NSMenu, inlineAccounts: NSMenu? = nil) {
        if !instances.isEmpty {
            let accounts = inlineAccounts ?? NSMenu(); accounts.autoenablesItems = false
            accounts.minimumWidth = 240
            if inlineAccounts != nil && !accounts.items.isEmpty { accounts.addItem(.separator()) }
            for instance in instances {
                let candidate = QuotaTarget(provider: .antigravity, instance: instance)
                var title = displayTitle(candidate)
                if !instance.supported { title += " · 未识别登录来源" }
                if blockedAccounts.contains(instance.id) { title += " · 账号已变化，重新勾选确认" }
                let item = NSMenuItem(title: title, action: #selector(toggleInstance(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = instance.id; item.isEnabled = instance.supported
                item.state = visibleTargets.contains(candidate) ? .on : .off
                item.image = accountAvatars[instance.id] ?? AvatarImage.placeholder(String((instances.firstIndex(of: instance) ?? 0) + 2))
                accounts.addItem(item)
            }
            if inlineAccounts == nil {
                let parent = NSMenuItem(title: "Antigravity 多实例", action: nil, keyEquivalent: ""); parent.submenu = accounts; menu.addItem(parent)
            }
        }
        let settings = NSMenu(); settings.autoenablesItems = false; settings.minimumWidth = 200
        for (title, action) in [("重新扫描实例", #selector(scanInstances)), ("手动添加实例…", #selector(addManualInstance)), ("修改当前账号别名…", #selector(renameAccount))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            item.isEnabled = !demo && !testMode && (action != #selector(renameAccount) || !visibleTargets.isEmpty)
            settings.addItem(item)
        }
        if let instance = target.instance, instance.manual {
            let remove = NSMenuItem(title: "移除此手动实例", action: #selector(removeManualInstance), keyEquivalent: ""); remove.target = self; settings.addItem(remove)
        }
        let parent = NSMenuItem(title: "账号设置", action: nil, keyEquivalent: ""); parent.submenu = settings; menu.addItem(parent)
    }
    @objc func toggleInstance(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let instance = instances.first(where: { $0.id == id }), instance.supported else { return }
        if blockedAccounts.remove(id) != nil { accountBindings[id] = nil; enabledInstances.insert(id) }
        else if !enabledInstances.insert(id).inserted { enabledInstances.remove(id) }
        saveAccountPreferences(); discoverInstalled()
        refresh(.init(provider: .antigravity, instance: instance))
    }
    @objc func renameAccount() {
        let candidate = target
        activeMenu?.cancelTracking()
        let alert = NSAlert(); alert.messageText = "修改账号别名"; alert.informativeText = "仅在本机显示，不修改原应用账号。"
        let field = NSTextField(string: accountAliases[candidate.id] ?? ""); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); field.placeholderString = candidate.title
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accountAliases[candidate.id] = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        saveAccountPreferences(); updateView()
    }
    @objc func addManualInstance() {
        activeMenu?.cancelTracking(); NSApp.activate(ignoringOtherApps: true)
        let app = NSOpenPanel(); app.title = "选择 Antigravity 实例应用"; app.allowedContentTypes = [.applicationBundle]; app.allowsMultipleSelection = false
        guard app.runModal() == .OK, let appURL = app.url else { return }
        guard AntigravityDiscovery.isApplication(appURL) else { accountAlert("所选应用不是支持的 Antigravity 实例"); return }
        let file = NSOpenPanel(); file.title = "选择该实例的登录 JSON 文件"; file.message = "支持含 token.access_token 和 token.refresh_token 的本地登录文件。不会修改文件或原应用。"; file.allowsMultipleSelection = false
        guard file.runModal() == .OK, let fileURL = file.url else { return }
        let instance = AntigravityInstance(appPath: appURL.path, credentialPath: fileURL.path, name: appURL.deletingPathExtension().lastPathComponent, manual: true)
        do { _ = try GoogleCredentials.read(instance: instance) }
        catch { accountAlert("无法读取受支持的登录格式，请确认属于该实例。"); return }
        manualInstances.removeAll { $0.appPath == instance.appPath && $0.credentialPath == instance.credentialPath }
        manualInstances.append(instance); saveAccountPreferences(); scanInstances()
    }
    @objc func removeManualInstance() {
        guard let instance = target.instance, instance.manual else { return }
        manualInstances.removeAll { $0.id == instance.id }; enabledInstances.remove(instance.id)
        accountBindings[instance.id] = nil; accountAliases[instance.id] = nil
        saveAccountPreferences(); scanInstances()
    }
    func accountAlert(_ message: String) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "好"); alert.runModal()
    }
    func updateRecoveryItem() {
        let needsRecovery = temporarilyHidden || (visibleTargets.isEmpty && (!detectedApps.isEmpty || !instances.isEmpty))
        if needsRecovery && recoveryItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "NotchQuota 账号设置")
            item.button?.toolTip = "NotchQuota · 选择显示的账号"
            item.menu = makeMenu(); recoveryItem = item
        } else if !needsRecovery, let item = recoveryItem { NSStatusBar.system.removeStatusItem(item); recoveryItem = nil }
        else if needsRecovery { recoveryItem?.menu = makeMenu() }
        recoveryItem?.button?.image = NSImage(systemSymbolName: temporarilyHidden ? "eye.slash" : "slider.horizontal.3", accessibilityDescription: "NotchQuota 设置")
        recoveryItem?.button?.toolTip = temporarilyHidden ? "NotchQuota · 临时隐藏，点击可立即显示" : "NotchQuota · 选择显示的账号"
    }
}
