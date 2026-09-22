import AppKit
import QuartzCore

struct ReminderCycle {
    var lastID: String?
    mutating func next(in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = lastID.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % ids.count } ?? 0
        lastID = ids[index]; return lastID
    }
}

enum ReminderFreshness {
    static func accepts(_ state: DisplayState, since started: Date) -> Bool {
        guard !state.loading, state.error == nil, !state.stale,
              let snapshot = state.snapshot, snapshot.fetchedAt >= started,
              snapshot.remaining != nil else { return false }
        return true
    }
}

struct ThoughtLayout {
    static let size = NSSize(width: 292, height: 186)
    static func frame(anchor: NSRect, screen: NSRect) -> NSRect {
        let above = anchor.maxY + size.height <= screen.maxY - 8
        let x = min(screen.maxX - size.width - 8, max(screen.minX + 8, anchor.midX - size.width / 2))
        let y = above ? anchor.maxY : anchor.minY - size.height
        return NSRect(x: x, y: min(screen.maxY - size.height - 8, max(screen.minY + 8, y)), width: size.width, height: size.height)
    }
}

final class ThoughtView: NSView {
    private let cloud = CALayer()
    private var dots: [CALayer] = []
    private var tracking: NSTrackingArea?
    var acceptsInput = true
    var enter: (() -> Void)?, leave: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.addSublayer(cloud)
        for diameter: CGFloat in [5, 9, 14] {
            let dot = CALayer(); dot.bounds.size = NSSize(width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2; dot.backgroundColor = NSColor(white: 0.99, alpha: 0.97).cgColor
            layer?.addSublayer(dot); dots.append(dot)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { if acceptsInput { enter?() } }
    override func mouseExited(with event: NSEvent) { if acceptsInput { leave?() } }
    func configure(account: OverviewAccount, anchor: NSRect, windowFrame: NSRect, animated: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cloud.sublayers?.forEach { $0.removeFromSuperlayer() }; cloud.removeAllAnimations()
        let above = windowFrame.midY > anchor.midY
        cloud.frame = NSRect(x: 8, y: above ? 38 : 8, width: 276, height: 140)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 31, y: 24))
        p.addCurve(to: CGPoint(x: 23, y: 100), control1: CGPoint(x: -6, y: 26), control2: CGPoint(x: -8, y: 90))
        p.addCurve(to: CGPoint(x: 99, y: 127), control1: CGPoint(x: 28, y: 137), control2: CGPoint(x: 65, y: 146))
        p.addCurve(to: CGPoint(x: 181, y: 128), control1: CGPoint(x: 123, y: 146), control2: CGPoint(x: 163, y: 145))
        p.addCurve(to: CGPoint(x: 246, y: 102), control1: CGPoint(x: 216, y: 145), control2: CGPoint(x: 245, y: 130))
        p.addCurve(to: CGPoint(x: 248, y: 30), control1: CGPoint(x: 284, y: 88), control2: CGPoint(x: 282, y: 42))
        p.addCurve(to: CGPoint(x: 181, y: 13), control1: CGPoint(x: 245, y: 1), control2: CGPoint(x: 205, y: -3))
        p.addCurve(to: CGPoint(x: 98, y: 12), control1: CGPoint(x: 157, y: -5), control2: CGPoint(x: 120, y: -5))
        p.addCurve(to: CGPoint(x: 31, y: 24), control1: CGPoint(x: 70, y: -4), control2: CGPoint(x: 36, y: 0)); p.closeSubpath()
        let shape = CAShapeLayer(); shape.path = p
        shape.fillColor = NSColor(srgbRed: 0.99, green: 0.985, blue: 1, alpha: 0.98).cgColor
        shape.shadowPath = p; shape.shadowColor = NSColor.black.cgColor; shape.shadowOpacity = 0.12
        shape.shadowRadius = 7; shape.shadowOffset = CGSize(width: 0, height: -3); cloud.addSublayer(shape)
        let icon = CALayer(); icon.frame = CGRect(x: 36, y: 96, width: 18, height: 18)
        icon.contents = account.image; icon.contentsGravity = .resizeAspect; cloud.addSublayer(icon)
        let ink = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.23, alpha: 1)
        func text(_ value: String, _ frame: CGRect, size: CGFloat, color: NSColor, bold: Bool = false) {
            let label = CATextLayer(); label.frame = frame; label.string = value
            label.font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            label.fontSize = size; label.foregroundColor = color.cgColor
            label.contentsScale = window?.backingScaleFactor ?? 2; label.truncationMode = .middle
            cloud.addSublayer(label)
        }
        text(account.title, CGRect(x: 62, y: 95, width: 180, height: 20), size: 13, color: ink, bold: true)
        let stale = account.state.stale
        let quota = account.state.snapshot?.windows.filter { $0.remaining != nil }.min { $0.remaining! < $1.remaining! }
        let percent = quota?.remaining.map { "\(Int($0.rounded()))%" } ?? "—"
        text("剩余", CGRect(x: 36, y: 62, width: 42, height: 25), size: 16, color: ink)
        text(percent, CGRect(x: 80, y: 60, width: 120, height: 30), size: 24,
             color: stale ? .secondaryLabelColor : QuotaTint.color(quota?.remaining), bold: true)
        let reset = quota.map { "\($0.label) · \(QuotaSummary.resetText($0.reset))" } ?? "暂时无法读取额度"
        text(reset, CGRect(x: 36, y: 40, width: 210, height: 17), size: 10, color: ink.withAlphaComponent(0.65))
        let subtitle = [stale ? "上次数据" : "", account.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
        text(subtitle, CGRect(x: 36, y: 22, width: 210, height: 15), size: 9, color: ink.withAlphaComponent(0.55))
        let tip = min(bounds.width - 12, max(12, anchor.midX - windowFrame.minX))
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            let step = CGFloat(index)
            dot.position = CGPoint(x: tip + (bounds.midX - tip) * step * 0.17,
                                   y: above ? 5 + step * 12 : bounds.height - 5 - step * 12)
        }
        CATransaction.commit()
        setAccessibilityElement(true); setAccessibilityLabel("\(account.title) \(subtitle) 剩余 \(percent)，\(reset)")
        guard animated else { return }
        for (index, part) in (dots + [cloud]).enumerated() {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            fade.duration = 0.22; fade.beginTime = CACurrentMediaTime() + Double(index) * 0.085
            fade.fillMode = .backwards; part.add(fade, forKey: "appear")
        }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.95; pop.toValue = 1; pop.damping = 24; pop.stiffness = 280; pop.duration = 0.4
        cloud.add(pop, forKey: "pop")
    }
}

@MainActor final class ThoughtReminder {
    let panel: NSPanel
    let view = ThoughtView(frame: NSRect(origin: .zero, size: ThoughtLayout.size))
    private(set) var timer: Timer?
    private var dismissal: DispatchWorkItem?
    private var generation = 0
    private var cycle = ReminderCycle()
    var tick: (() -> Void)?
    init() {
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view; panel.title = "额度思考泡泡"
        view.enter = { [weak self] in self?.dismissal?.cancel(); self?.dismissal = nil }
        view.leave = { [weak self] in self?.dismiss(after: 0.3) }
    }
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick?() } }
        timer.tolerance = 15; self.timer = timer; RunLoop.main.add(timer, forMode: .default)
    }
    func stop() { timer?.invalidate(); timer = nil; hide() }
    func showNext(accounts: [OverviewAccount], anchor: NSRect, screen: NSRect, animated: Bool) {
        guard let id = cycle.next(in: accounts.map(\.id)), let account = accounts.first(where: { $0.id == id }) else { return }
        hide()
        let frame = ThoughtLayout.frame(anchor: anchor, screen: screen)
        panel.setFrame(frame, display: false)
        view.configure(account: account, anchor: anchor, windowFrame: frame, animated: animated)
        panel.alphaValue = 1; panel.orderFrontRegardless(); dismiss(after: 5)
    }
    func hide() {
        generation += 1; dismissal?.cancel(); dismissal = nil
        panel.orderOut(nil); panel.alphaValue = 1; view.layer?.removeAllAnimations()
    }
    private func dismiss(after delay: Double) {
        dismissal?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation else { return }
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.22
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration; self.panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, token == self.generation else { return }; self.hide()
                }
            }
        }
        dismissal = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
