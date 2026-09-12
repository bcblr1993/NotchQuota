import AppKit

extension Provider {
    @MainActor private static let icons: [Provider: NSImage] = Dictionary(uniqueKeysWithValues: allCases.map {
        let source = ResourceLocator.icon($0.rawValue).flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: $0.title)!
        return ($0, normalizedIcon(source))
    })
    @MainActor var icon: NSImage { Self.icons[self]! }
    /// Strip different transparent margins once, then give every mark the same 16 pt box.
    @MainActor private static func normalizedIcon(_ source: NSImage) -> NSImage {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
        for y in 0..<cg.height { for x in 0..<cg.width {
            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.12 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        } }
        guard maxX >= minX, maxY >= minY,
              let crop = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return source }
        let scale = 16 / CGFloat(max(crop.width, crop.height))
        return NSImage(cgImage: crop, size: NSSize(width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale))
    }

}
enum QuotaTint {
    static func color(_ remaining: Double?) -> NSColor {
        guard let value = remaining else { return NSColor(white: 0.55, alpha: 1) }
        if value > 50 { return NSColor(srgbRed: 0.38, green: 0.86, blue: 0.60, alpha: 1) }
        if value >= 20 { return NSColor(srgbRed: 0.95, green: 0.78, blue: 0.37, alpha: 1) }
        return NSColor(srgbRed: 1, green: 0.44, blue: 0.48, alpha: 1)
    }
}
struct DisplayState {
    var snapshot: Snapshot?
    var error: String?
    var loading = false
    var stale: Bool { snapshot != nil && (error != nil || Date().timeIntervalSince(snapshot!.fetchedAt) > 600) }
}
// Pure idle state: polling and background quota updates never count as interaction.
struct IdleState {
    static let delay: TimeInterval = 15
    var lastInteraction: TimeInterval = 0
    var active = true
    mutating func interact(at time: TimeInterval) { lastInteraction = time; active = true }
    mutating func tick(at time: TimeInterval) -> Bool {
        if active && time - lastInteraction >= Self.delay { active = false; return true }
        return false
    }
}
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class QuotaButton: NSButton {
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}
final class QuotaView: NSView {
    var provider: Provider = .codex
    var nextProviderTitle: String?
    var accountTitle: String?
    var accountImage: NSImage?
    var state = DisplayState()
    var topHeight: CGFloat = 32
    var cameraWidth: CGFloat = 0
    var expanded = false
    var updateVersion: String?
    var onUpdate: (() -> Void)?
    var onSwitch: (() -> Void)?
    var onExpand: (() -> Void)?
    var onActivity: (() -> Void)?
    var onLeave: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    private let updateButton = QuotaButton()
    private let iconButton = QuotaButton()
    private let quotaButton = QuotaButton()
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for button in [iconButton, quotaButton, updateButton] {
            button.isBordered = false; button.bezelStyle = .regularSquare
            button.target = self; button.focusRingType = .exterior
            addSubview(button)
        }
        updateButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "可更新")
        updateButton.contentTintColor = .systemBlue
        updateButton.imageScaling = .scaleProportionallyDown
        updateButton.action = #selector(showUpdate)
        iconButton.imagePosition = .imageOnly
        iconButton.imageScaling = .scaleProportionallyDown
        iconButton.action = #selector(nextProvider)
        quotaButton.action = #selector(toggleDetails)
        setAccessibilityElement(false)
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update() {
        updateButton.isHidden = updateVersion == nil
        updateButton.toolTip = updateVersion.map { "新版本 \($0) 可更新，点击下载安装" }
        updateButton.setAccessibilityLabel(updateButton.toolTip ?? "检查更新")
        iconButton.image = accountImage ?? provider.icon
        iconButton.toolTip = nextProviderTitle.map { "切换至 \($0)" } ?? (accountTitle ?? provider.title)
        iconButton.setAccessibilityLabel(nextProviderTitle.map { "当前 \(accountTitle ?? provider.title)，切换至 \($0)" } ?? "当前 \(accountTitle ?? provider.title)")
        quotaButton.title = ""
        quotaButton.setAccessibilityLabel("\(provider.title) 剩余额度 \(percentage)，\(expanded ? "收起详情" : "显示详情")")
        quotaButton.toolTip = state.error ?? (state.stale ? "上次读取的额度，等待更新" : (expanded ? "点击收起详情" : "剩余额度 · 点击展开"))
        layoutButtons()
        needsDisplay = true
    }
    private func layoutButtons() {
        let compactWidth = cameraWidth > 0 ? cameraWidth + 94 : 100
        let x = (bounds.width - compactWidth) / 2
        iconButton.frame = NSRect(x: x + 5, y: (topHeight - 26) / 2, width: 26, height: 26)
        updateButton.frame = NSRect(x: x + 32, y: (topHeight - 12) / 2, width: 12, height: 12)
        quotaButton.frame = NSRect(x: bounds.width - x - 60, y: 0, width: 55, height: topHeight)
    }
    var percentage: String {
        guard let remaining = state.snapshot?.remaining else { return "—" }
        return "\(Int(remaining.rounded()))%"
    }
    override func layout() { super.layout(); layoutButtons(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onActivity?() }
    override func mouseMoved(with event: NSEvent) { onActivity?() }
    override func mouseExited(with event: NSEvent) { onLeave?() }
    override func rightMouseDown(with event: NSEvent) { onActivity?(); onContextMenu?(event) }
    override func mouseDown(with event: NSEvent) { onActivity?() }
    @objc private func showUpdate() { onUpdate?() }
    @objc private func nextProvider() { onActivity?(); onSwitch?() }
    @objc private func toggleDetails() { onActivity?(); onExpand?() }
    private func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, color: NSColor = .white, weight: NSFont.Weight = .regular, width: CGFloat? = nil, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.alignment = align; style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
        (value as NSString).draw(in: NSRect(x: x, y: y, width: width ?? bounds.width - x - 16, height: size + 6), withAttributes: attrs)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.025, green: 0.025, blue: 0.03, alpha: 1).setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: expanded ? 19 : 12, yRadius: expanded ? 19 : 12)
        path.fill()
        // Square top joins the physical notch; the actual camera remains empty.
        NSRect(x: 0, y: 0, width: bounds.width, height: min(12, topHeight)).fill()
        path.addClip() // Keep revealed rows inside the rounded bottom during resizing.
        let tint = state.stale ? NSColor(white: 0.55, alpha: 1) : QuotaTint.color(state.snapshot?.remaining)
        let button = quotaButton.frame
        text(percentage, x: button.minX + 2, y: (topHeight - 17) / 2, size: 12, color: tint, weight: .medium, width: button.width - 7, align: .right)
        if state.loading || state.stale {
            (state.stale ? NSColor(white: 0.65, alpha: 1) : tint).setFill()
            NSBezierPath(ovalIn: NSRect(x: button.minX + 3, y: topHeight / 2 - 1.5, width: 3, height: 3)).fill()
        }
        guard expanded || bounds.height > topHeight + 1 else { return }
        let muted = NSColor(white: 0.61, alpha: 1)
        let rows = state.snapshot?.windows ?? []
        var y = topHeight + 12
        text(accountTitle ?? (state.stale ? "上次剩余额度" : "剩余额度"), x: 17, y: y + 7, size: 11, color: muted, width: bounds.width - 125)
        text(percentage, x: bounds.width - 96, y: y, size: 24, color: tint, weight: .medium, width: 79, align: .right)
        y += 39
        if rows.isEmpty {
            let message = state.error ?? "正在读取本机账号额度…"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted]
            (message as NSString).draw(in: NSRect(x: 17, y: y, width: bounds.width - 34, height: 47), withAttributes: attrs)
            return
        }
        for row in rows.prefix(6) {
            text(row.label, x: 17, y: y, size: 10.5, color: NSColor(white: 0.84, alpha: 1), width: bounds.width - 77)
            let value = row.remaining.map { "\(Int($0.rounded()))%" } ?? "—"
            text(value, x: bounds.width - 61, y: y, size: 10.5, color: muted, width: 44, align: .right)
            y += 19
            let rect = NSRect(x: 17, y: y, width: bounds.width - 34, height: 3)
            NSColor(white: 0.14, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            if let value = row.remaining, value > 0 {
                (state.stale ? muted : QuotaTint.color(value)).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * value / 100, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
            y += 13
        }
        let footer: String
        if let error = state.error { footer = "更新失败 · " + error }
        else if let reset = rows.min(by: { ($0.remaining ?? 101) < ($1.remaining ?? 101) })?.reset {
            let seconds = max(0, reset.timeIntervalSinceNow)
            footer = seconds > 86400 ? "\(Int(ceil(seconds / 86400))) 天内重置" : seconds > 3600 ? "\(Int(seconds / 3600)) 小时 \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) 分后重置" : "\(Int(ceil(seconds / 60))) 分钟后重置"
        } else { footer = "刚刚更新" }
        text(footer, x: 17, y: y + 3, size: 10, color: muted, width: bounds.width - 34)
    }
}
