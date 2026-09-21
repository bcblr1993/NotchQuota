import AppKit
import SwiftUI
import QuartzCore

/// Geometry is independent of mouse tracking and quota fetching.
enum SidebarLayout {
    static let width: CGFloat = 52
    static let rowHeight: CGFloat = 54
    static let inset: CGFloat = 0
    static func frame(count: Int, screen: NSRect, right: Bool, fraction: Double) -> NSRect {
        let height = min(max(40, screen.height - 24), CGFloat(count) * rowHeight + 20)
        let y = screen.minY + 12 + max(0, screen.height - height - 24) * CGFloat(min(1, max(0, fraction)))
        return NSRect(x: right ? screen.maxX - width - inset : screen.minX + inset, y: y, width: width, height: height)
    }
    static func floatingFrame(count: Int, screen: NSRect, xFraction: Double, yFraction: Double) -> NSRect {
        var result = frame(count: count, screen: screen, right: false, fraction: yFraction)
        result.origin.x = screen.minX + 10 + max(0, screen.width - width - 20) * CGFloat(min(1, max(0, xFraction)))
        return result
    }
    static func collapsedFrame(expanded: NSRect, screen: NSRect, docked: Bool, right: Bool) -> NSRect {
        let width: CGFloat = docked ? 18 : 40
        return NSRect(x: docked ? (right ? screen.maxX - width : screen.minX) : expanded.midX - width / 2,
                      y: min(screen.maxY - 44, max(screen.minY, expanded.midY - 22)), width: width, height: 44)
    }
    static func detailFrame(bar: NSRect, rowY: CGFloat, size: NSSize, screen: NSRect, right: Bool) -> NSRect {
        let width = min(size.width, screen.width - 24), height = min(size.height, screen.height - 24)
        let x = right ? bar.minX - width - 8 : bar.maxX + 8
        return NSRect(x: min(max(screen.minX + 8, x), screen.maxX - width - 8),
                      y: min(max(screen.minY + 8, rowY - height / 2), screen.maxY - height - 8), width: width, height: height)
    }
}

/// Layer-backed cell: values only update when changed; tracking uses enter/exit events, never polling.
final class SidebarCell: NSView {
    let id: String
    let halo = CAGradientLayer()
    let artwork = CALayer(), ring = CAShapeLayer(), track = CAShapeLayer(), icon = CALayer(), number = CATextLayer()
    var enter: (() -> Void)?, leave: (() -> Void)?, click: (() -> Void)?
    var drag: ((NSEvent) -> Void)?, context: ((NSEvent, NSView) -> Void)?
    var motion: TimeInterval = 0.2
    private var tracking: NSTrackingArea?
    private var down: NSEvent?
    private var value: Double?, image: NSImage?, dimmed = false
    private(set) var highlighted = false
    init(id: String) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: SidebarLayout.width, height: SidebarLayout.rowHeight))
        wantsLayer = true
        halo.frame = NSRect(x: 5, y: 1, width: 42, height: 52)
        halo.colors = [NSColor(red: 0.46, green: 0.55, blue: 0.9, alpha: 0.24).cgColor,
                       NSColor(red: 0.33, green: 0.73, blue: 0.83, alpha: 0.07).cgColor]
        halo.startPoint = CGPoint(x: 0, y: 1); halo.endPoint = CGPoint(x: 1, y: 0)
        halo.cornerRadius = 19; halo.opacity = 0; layer?.addSublayer(halo)
        artwork.bounds = NSRect(x: 0, y: 0, width: 32, height: 32); artwork.position = NSPoint(x: 26, y: 35)
        let path = CGMutablePath(); path.addArc(center: CGPoint(x: 16, y: 16), radius: 13.5, startAngle: .pi / 2, endAngle: -.pi * 1.5, clockwise: true)
        for shape in [track, ring] {
            shape.frame = artwork.bounds; shape.path = path; shape.fillColor = nil; shape.lineWidth = 2; shape.lineCap = .round
            artwork.addSublayer(shape)
        }
        track.strokeColor = NSColor(white: 1, alpha: 0.13).cgColor
        ring.strokeEnd = 0
        icon.frame = NSRect(x: 7, y: 7, width: 18, height: 18); icon.contentsGravity = .resizeAspect
        icon.cornerRadius = 9; icon.masksToBounds = true; artwork.addSublayer(icon)
        number.frame = NSRect(x: 0, y: 1, width: 52, height: 15); number.fontSize = 10
        number.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        number.alignmentMode = .center; number.foregroundColor = NSColor.white.cgColor
        layer?.addSublayer(artwork); layer?.addSublayer(number)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        number.contentsScale = window?.backingScaleFactor ?? 2; icon.contentsScale = number.contentsScale
    }
    func update(_ account: OverviewAccount, duration: TimeInterval) {
        motion = duration
        let remaining = account.state.snapshot?.remaining
        let stale = account.state.stale || account.state.error != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if image !== account.image {
            image = account.image
            icon.contents = account.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if value != remaining || dimmed != stale || number.string == nil {
            let previous = ring.presentation()?.strokeEnd ?? ring.strokeEnd
            value = remaining; dimmed = stale
            ring.strokeEnd = CGFloat(min(100, max(0, remaining ?? 0))) / 100
            ring.strokeColor = QuotaTint.color(stale ? nil : remaining).cgColor
            number.string = remaining.map { "\(Int($0.rounded()))%" } ?? "—"
            number.foregroundColor = (stale ? NSColor.gray : NSColor.white).cgColor
            if duration > 0 {
                let animation = CABasicAnimation(keyPath: "strokeEnd"); animation.fromValue = previous; animation.toValue = ring.strokeEnd
                animation.duration = duration; animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ring.add(animation, forKey: "quota")
            } else { ring.removeAllAnimations() }
        }
        CATransaction.commit()
        let label = account.title + (account.subtitle.isEmpty ? "" : " · " + account.subtitle)
        toolTip = label; setAccessibilityLabel(label + " · " + (remaining.map { "\(Int($0))%" } ?? "未知额度"))
    }
    func highlight(_ enabled: Bool) {
        guard highlighted != enabled else { return }; highlighted = enabled
        let old = artwork.presentation()?.transform ?? artwork.transform
        let oldOpacity = halo.presentation()?.opacity ?? halo.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.opacity = enabled ? 1 : 0
        artwork.transform = CATransform3DMakeScale(enabled ? 1.10 : 1, enabled ? 1.10 : 1, 1)
        CATransaction.commit()
        artwork.removeAllAnimations()
        if motion > 0 {
            let glow = CABasicAnimation(keyPath: "opacity")
            glow.fromValue = oldOpacity; glow.toValue = halo.opacity; glow.duration = 0.22
            halo.add(glow, forKey: "hover")
            let spring = CASpringAnimation(keyPath: "transform"); spring.fromValue = NSValue(caTransform3D: old); spring.toValue = NSValue(caTransform3D: artwork.transform)
            spring.mass = 1; spring.stiffness = 340; spring.damping = 28; spring.duration = 0.28
            artwork.add(spring, forKey: "hover")
        }
    }
    func stopAnimations() { artwork.removeAllAnimations(); ring.removeAllAnimations(); halo.removeAllAnimations(); layer?.removeAllAnimations() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { enter?() }
    override func mouseExited(with event: NSEvent) { leave?() }
    override func mouseDown(with event: NSEvent) { down = event }
    override func mouseDragged(with event: NSEvent) {
        guard let original = down, hypot(event.locationInWindow.x - original.locationInWindow.x, event.locationInWindow.y - original.locationInWindow.y) > 3 else { return }
        down = nil; drag?(original)
    }
    override func mouseUp(with event: NSEvent) { if down != nil { down = nil; click?() } }
    override func rightMouseDown(with event: NSEvent) { context?(event, self) }
    override func accessibilityPerformPress() -> Bool { click?(); return true }
}

final class SidebarSurface: NSView {
    var entered: (() -> Void)?, exited: (() -> Void)?, drag: ((NSEvent) -> Void)?, context: ((NSEvent, NSView) -> Void)?
    private var tracking: NSTrackingArea?
    private let finish = CAGradientLayer()
    var laidOut: (() -> Void)?
    func applyFinish() {
        finish.colors = [NSColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1).cgColor,
                         NSColor(red: 0.045, green: 0.05, blue: 0.075, alpha: 1).cgColor,
                         NSColor(red: 0.035, green: 0.07, blue: 0.08, alpha: 1).cgColor]
        finish.locations = [0, 0.55, 1]
        finish.startPoint = CGPoint(x: 0, y: 1); finish.endPoint = CGPoint(x: 1, y: 0)
        layer?.insertSublayer(finish, at: 0)
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(red: 0.7, green: 0.79, blue: 0.94, alpha: 0.22).cgColor
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        finish.frame = bounds
        laidOut?()
        CATransaction.commit()
    }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
    override func mouseDown(with event: NSEvent) { drag?(event) }
    override func rightMouseDown(with event: NSEvent) { context?(event, self) }
}

@MainActor final class SidebarController {
    let panel: NSPanel
    let detail: NSPanel
    let surface = SidebarSurface(frame: .zero), detailSurface = SidebarSurface(frame: .zero)
    let scroll = NSScrollView(), document = NSView()
    let model: OverviewModel
    private var detailHost: NSView?
    private let pointer = CAShapeLayer()
    private(set) var cells: [SidebarCell] = []
    private(set) var selectedID: String?
    private(set) var pinned = false
    private(set) var hoverWork: DispatchWorkItem?, closeWork: DispatchWorkItem?
    private(set) var clock: Timer?
    private(set) var right = true
    private var fraction = 0.5
    private var xFraction = 0.5
    private(set) var docked = true
    private(set) var collapsed = false
    private(set) var autoCollapse = true
    private(set) var idleWork: DispatchWorkItem?
    private var pointerInBar = false, pointerInDetail = false, dragging = false
    private let face = CALayer()
    private let leftEye = CALayer(), rightEye = CALayer()
    private var screenID: UInt32?
    private var motion: TimeInterval = 0.2
    private var generation = 0
    private var selecting = false
    private var accounts: [OverviewAccount] = []
    private var visibleScreen: NSScreen { NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == screenID } ?? NSScreen.main ?? NSScreen.screens[0] }
    var onSelect: ((String) -> Void)?, onMenu: ((NSEvent?, NSView) -> Void)?
    var acceptsInput = true
    let persist: Bool
    init(model: OverviewModel, persist: Bool) {
        self.model = model; self.persist = persist
        func window(_ title: String) -> NSPanel {
            let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = title; p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.level = .floating; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]; p.appearance = NSAppearance(named: .darkAqua)
            return p
        }
        panel = window("NotchQuota 侧边栏"); detail = window("NotchQuota 账号详情")
        if persist {
            let d = UserDefaults.standard
            right = d.object(forKey: "sidebarRight") as? Bool ?? true
            fraction = d.object(forKey: "sidebarPosition") as? Double ?? 0.5
            screenID = d.object(forKey: "sidebarScreen") as? UInt32
            docked = d.object(forKey: "sidebarDocked") as? Bool ?? true
            xFraction = d.object(forKey: "sidebarX") as? Double ?? 0.5
            autoCollapse = d.object(forKey: "sidebarAutoCollapse") as? Bool ?? true
        }
        panel.contentView = surface; surface.layer?.backgroundColor = NSColor(white: 0.035, alpha: 0.97).cgColor
        surface.applyFinish()
        surface.layer?.cornerRadius = 26; surface.layer?.masksToBounds = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.documentView = document; surface.addSubview(scroll)
        surface.laidOut = { [weak self] in
            guard let self else { return }
            self.face.position = CGPoint(x: self.surface.bounds.midX, y: self.surface.bounds.midY)
        }
        scroll.autoresizingMask = [.width, .height]
        face.isHidden = true; surface.layer?.addSublayer(face)
        for (eye, x) in [(leftEye, 3.0), (rightEye, 9.0)] {
            eye.frame = CGRect(x: x, y: 3, width: 3, height: 5)
            eye.cornerRadius = 1.5; eye.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
            face.addSublayer(eye)
        }
        surface.entered = { [weak self] in if self?.acceptsInput == true { self?.enterBar() } }
        surface.exited = { [weak self] in if self?.acceptsInput == true { self?.exitBar() } }
        detail.contentView = detailSurface
        detailSurface.layer?.masksToBounds = false
        let host = NSHostingView(rootView: QuotaOverview(model: model).preferredColorScheme(.dark))
        detailHost = host; host.wantsLayer = true
        host.layer?.cornerRadius = 16; host.layer?.masksToBounds = true
        host.frame = detailSurface.bounds; host.autoresizingMask = [.height]; detailSurface.addSubview(host)
        pointer.fillColor = NSColor(white: 0.045, alpha: 1).cgColor; detailSurface.layer?.addSublayer(pointer)
        surface.drag = { [weak self] event in if self?.acceptsInput == true { self?.drag(event) } }
        surface.context = { [weak self] event, view in if self?.acceptsInput == true { self?.showMenu(event, view) } }
        detailSurface.entered = { [weak self] in if self?.acceptsInput == true { self?.pointerInDetail = true; self?.cancelIdle(); self?.cancelClose() } }
        detailSurface.exited = { [weak self] in if self?.acceptsInput == true { self?.pointerInDetail = false; self?.scheduleClose(); self?.scheduleIdleCollapse() } }
    }
    func update(_ values: [OverviewAccount], duration: TimeInterval) {
        motion = duration; accounts = values
        if cells.map(\.id) != values.map(\.id) {
            dismiss(animated: false)
            for cell in cells { cell.removeFromSuperview() }
            cells = values.map { account in
                let cell = SidebarCell(id: account.id)
                cell.enter = { [weak self] in if self?.acceptsInput == true { self?.hover(account.id) } }
                cell.leave = { [weak self] in if self?.acceptsInput == true { self?.leave(account.id) } }
                cell.click = { [weak self] in if self?.acceptsInput == true { self?.select(account.id, pin: true) } }
                cell.drag = { [weak self] event in if self?.acceptsInput == true { self?.drag(event) } }
                cell.context = { [weak self] event, view in if self?.acceptsInput == true { self?.showMenu(event, view) } }
                document.addSubview(cell); return cell
            }
            position()
        }
        for (cell, value) in zip(cells, values) { cell.update(value, duration: panel.isVisible ? duration : 0) }
        if duration == 0 { for cell in cells { cell.stopAnimations() }; detailSurface.layer?.removeAllAnimations(); surface.layer?.removeAllAnimations(); face.removeAllAnimations() }
        if !panel.isVisible && !values.isEmpty { position(); panel.orderFrontRegardless(); scheduleIdleCollapse() }
        if !selecting, detail.isVisible, let selectedID, values.contains(where: { $0.id == selectedID }) { positionDetail(animated: false) }
    }
    func position() {
        let screen = visibleScreen
        let expanded = expandedFrame(on: screen)
        let frame = collapsed ? SidebarLayout.collapsedFrame(expanded: expanded, screen: screen.visibleFrame, docked: docked, right: right) : expanded
        panel.setFrame(frame, display: true)
        scroll.isHidden = collapsed; face.isHidden = !collapsed
        surface.layer?.cornerRadius = collapsed ? min(frame.width / 2, 18) : 26
        CATransaction.begin(); CATransaction.setDisableActions(true)
        face.bounds = CGRect(x: 0, y: 0, width: 15, height: 11)
        face.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        CATransaction.commit()
        scroll.frame = NSRect(x: 0, y: 10, width: frame.width, height: max(0, frame.height - 20))
        document.frame = NSRect(x: 0, y: 0, width: 52, height: CGFloat(cells.count) * 54)
        for (index, cell) in cells.enumerated() { cell.frame.origin = NSPoint(x: 0, y: CGFloat(cells.count - index - 1) * 54) }
        if !cells.isEmpty { document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.bounds.height))) }
    }
    func expandedFrame(on screen: NSScreen) -> NSRect {
        docked ? SidebarLayout.frame(count: cells.count, screen: screen.visibleFrame, right: right, fraction: fraction)
            : SidebarLayout.floatingFrame(count: cells.count, screen: screen.visibleFrame, xFraction: xFraction, yFraction: fraction)
    }
    func cancelIdle() { idleWork?.cancel(); idleWork = nil }
    func scheduleIdleCollapse(after delay: TimeInterval = 3) {
        cancelIdle()
        guard autoCollapse, !collapsed, !pinned, !pointerInBar, !pointerInDetail, !dragging, panel.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in self?.idleWork = nil; self?.setCollapsed(true) }
        idleWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func enterBar() { pointerInBar = true; cancelIdle(); if !dragging { setCollapsed(false) } }
    func exitBar() { pointerInBar = false; scheduleIdleCollapse() }
    func setCollapsed(_ value: Bool) {
        guard collapsed != value, !dragging, !value || (!pinned && !pointerInBar && !pointerInDetail) else { return }
        cancelIdle()
        if value { dismiss(animated: false) }
        let old = panel.frame
        collapsed = value; position()
        let new = panel.frame
        guard motion > 0, panel.isVisible else { return }
        // Animate window geometry once; no display-link or idle animation loop.
        panel.setFrame(old, display: false)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = value ? 0.26 : 0.32
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.25, 1)
            panel.animator().setFrame(new, display: true)
        }
        let spring = CASpringAnimation(keyPath: "transform.scale.y")
        spring.fromValue = value ? 0.92 : 0.96; spring.toValue = 1; spring.stiffness = 320; spring.damping = 24; spring.duration = 0.36
        surface.layer?.add(spring, forKey: "fold")
        if !value {
            // A bounded cascade on visible rows only; no timers or continuously animated gradients.
            for (index, cell) in cells.filter({ $0.frame.intersects(scroll.documentVisibleRect) }).reversed().enumerated() {
                let reveal = CAAnimationGroup()
                let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
                let rise = CABasicAnimation(keyPath: "transform.translation.y"); rise.fromValue = -4; rise.toValue = 0
                reveal.animations = [fade, rise]; reveal.duration = 0.22
                reveal.beginTime = CACurrentMediaTime() + min(Double(index) * 0.018, 0.10)
                reveal.fillMode = .backwards
                reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cell.layer?.add(reveal, forKey: "unfold")
            }
        }
        if value {
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 0.15, 1]; blink.keyTimes = [0, 0.45, 1]; blink.duration = 0.3
            face.add(blink, forKey: "blink")
        }
    }
    func toggleAutoCollapse() {
        autoCollapse.toggle(); cancelIdle()
        if autoCollapse { scheduleIdleCollapse() } else { setCollapsed(false) }
        if persist { UserDefaults.standard.set(autoCollapse, forKey: "sidebarAutoCollapse") }
    }
    func screenChanged() { cancelIdle(); dismiss(animated: false); position(); scheduleIdleCollapse() }
    func hover(_ id: String) {
        cancelIdle(); setCollapsed(false)
        cancelClose(); hoverWork?.cancel(); hoverWork = nil
        cells.first { $0.id == id }?.highlight(true)
        guard !pinned else { return }
        if detail.isVisible { select(id, pin: false); return }
        let work = DispatchWorkItem { [weak self] in self?.hoverWork = nil; self?.select(id, pin: false) }
        hoverWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func leave(_ id: String) {
        hoverWork?.cancel(); hoverWork = nil
        if !(pinned && selectedID == id) { cells.first { $0.id == id }?.highlight(false) }
        scheduleClose(); scheduleIdleCollapse()
    }
    func select(_ id: String, pin: Bool) {
        guard panel.isVisible, accounts.contains(where: { $0.id == id }) else { return }
        cancelIdle(); setCollapsed(false)
        hoverWork?.cancel(); hoverWork = nil; cancelClose()
        if pin && pinned && selectedID == id { dismiss(animated: true); return }
        pinned = pin; model.pinned = pinned
        let changed = selectedID != id; selectedID = id
        for cell in cells { cell.highlight(cell.id == id) }
        selecting = true; onSelect?(id); selecting = false
        let wasVisible = detail.isVisible
        positionDetail(animated: wasVisible && changed)
        detail.alphaValue = 1
        if !wasVisible { detail.orderFrontRegardless() }
        if motion > 0 && (!wasVisible || changed) {
            let fade = CATransition(); fade.type = .fade; fade.duration = motion
            detailSurface.layer?.add(fade, forKey: "account")
            if !wasVisible {
                let spring = CASpringAnimation(keyPath: "transform.scale"); spring.fromValue = 0.965; spring.toValue = 1
                spring.stiffness = 360; spring.damping = 30; spring.duration = 0.28
                detailSurface.layer?.add(spring, forKey: "reveal")
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = right ? 5 : -5; slide.toValue = 0; slide.duration = motion
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                detailSurface.layer?.add(slide, forKey: "slide")
            }
        }
        if clock == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in guard let self, self.detail.isVisible else { return }; self.model.now = Date() }
            }
            timer.tolerance = 5; clock = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func positionDetail(animated: Bool) {
        guard let cell = cells.first(where: { $0.id == selectedID }), let account = model.accounts.first else { return }
        let row = panel.convertToScreen(cell.convert(cell.bounds, to: nil))
        let height = OverviewLayout.height(windowCount: account.state.snapshot?.windows.count ?? 0,
                                          hasNotice: account.state.error != nil || account.state.stale, availableHeight: visibleScreen.visibleFrame.height)
        let frame = SidebarLayout.detailFrame(bar: panel.frame, rowY: row.midY, size: NSSize(width: OverviewLayout.width + 8, height: height), screen: visibleScreen.visibleFrame, right: right)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        detailHost?.frame = NSRect(x: right ? 0 : 8, y: 0, width: OverviewLayout.width, height: frame.height)
        pointer.frame = NSRect(origin: .zero, size: frame.size)
        let tipY = min(frame.height - 20, max(20, row.midY - frame.minY))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: right ? frame.width - 8 : 8, y: tipY - 6))
        path.addLine(to: CGPoint(x: right ? frame.width : 0, y: tipY))
        path.addLine(to: CGPoint(x: right ? frame.width - 8 : 8, y: tipY + 6)); path.closeSubpath()
        pointer.path = path
        CATransaction.commit()
        if animated && motion > 0 {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = motion; c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                detail.animator().setFrame(frame, display: true)
            }
        } else { detail.setFrame(frame, display: true) }
    }
    func togglePin() {
        guard let selectedID else { return }
        if pinned { pinned = false; model.pinned = false; if !pointerInBar && !pointerInDetail { scheduleClose(); scheduleIdleCollapse() } }
        else { select(selectedID, pin: true) }
    }
    func cancelClose() { generation += 1; closeWork?.cancel(); closeWork = nil; detail.alphaValue = 1 }
    func scheduleClose() {
        guard !pinned else { return }
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        closeWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func dismiss(animated: Bool) {
        hoverWork?.cancel(); hoverWork = nil; closeWork?.cancel(); closeWork = nil
        clock?.invalidate(); clock = nil; pinned = false; model.pinned = false; selectedID = nil
        for cell in cells { cell.highlight(false) }
        generation += 1; let token = generation
        detailSurface.layer?.removeAllAnimations()
        guard animated && motion > 0 && detail.isVisible else { detail.orderOut(nil); detail.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in context.duration = motion; detail.animator().alphaValue = 0 }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.detail.orderOut(nil); self.detail.alphaValue = 1; self.closeWork = nil
        }
        closeWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + motion, execute: work)
    }
    func hide() {
        cancelIdle(); dismiss(animated: false); cells.forEach { $0.stopAnimations() }
        surface.layer?.removeAllAnimations(); face.removeAllAnimations()
        pointerInBar = false; pointerInDetail = false; panel.orderOut(nil)
    }
    private func drag(_ event: NSEvent) {
        cancelIdle(); dismiss(animated: false); dragging = true
        let before = panel.frame
        panel.performDrag(with: event)
        dragging = false
        if before == panel.frame { setCollapsed(false); return }
        let point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? visibleScreen
        place(at: point, screen: screen)
        pointerInBar = panel.frame.contains(NSEvent.mouseLocation)
        scheduleIdleCollapse()
    }
    func place(at point: NSPoint, screen: NSScreen) {
        cancelIdle(); collapsed = false
        screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        right = point.x >= screen.visibleFrame.midX
        docked = min(abs(point.x - screen.visibleFrame.minX), abs(point.x - screen.visibleFrame.maxX)) <= 52
        let height = SidebarLayout.frame(count: cells.count, screen: screen.visibleFrame, right: right, fraction: 0.5).height
        let range = max(1, screen.visibleFrame.height - height - 24)
        fraction = Double(min(1, max(0, (point.y - height / 2 - screen.visibleFrame.minY - 12) / range)))
        xFraction = Double(min(1, max(0, (point.x - screen.visibleFrame.minX - 36) / max(1, screen.visibleFrame.width - 72))))
        position()
        if persist {
            let d = UserDefaults.standard
            d.set(right, forKey: "sidebarRight"); d.set(fraction, forKey: "sidebarPosition"); d.set(screenID, forKey: "sidebarScreen")
            d.set(docked, forKey: "sidebarDocked"); d.set(xFraction, forKey: "sidebarX")
        }
    }
    func showMenu(_ event: NSEvent?, _ view: NSView) { cancelIdle(); dismiss(animated: false); onMenu?(event, view); scheduleIdleCollapse() }
}

@MainActor extension AppDelegate {
    func sidebarAccounts() -> [OverviewAccount] {
        visibleTargets.map { candidate in
            OverviewAccount(id: candidate.id, title: accountAliases[candidate.id].flatMap { $0.isEmpty ? nil : $0 } ?? candidate.title,
                            subtitle: accountNames[candidate.id] ?? "", image: accountAvatars[candidate.id] ?? candidate.provider.icon,
                            state: states[candidate] ?? DisplayState())
        }
    }
    func updateSidebar() {
        guard displayMode == .sidebar else { sidebar?.hide(); return }
        panel?.orderOut(nil)
        guard !temporarilyHidden, !refreshSuspended, !visibleTargets.isEmpty else { sidebar?.hide(); return }
        if sidebar == nil {
            let controller = SidebarController(model: overviewModel, persist: !demo && !testMode)
            controller.acceptsInput = !testMode
            controller.onSelect = { [weak self] id in
                guard let self, let selected = self.visibleTargets.first(where: { $0.id == id }) else { return }
                self.target = selected; self.updateOverview()
            }
            controller.onMenu = { [weak self] event, view in
                guard let self else { return }
                let menu = self.makeMenu(); self.activeMenu = menu
                if let event { NSMenu.popUpContextMenu(menu, with: event, for: view) }
                else { menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX, y: view.bounds.minY), in: view) }
                self.activeMenu = nil
            }
            sidebar = controller
        }
        overviewModel.sidebarMode = true
        overviewModel.pin = { [weak self] in self?.sidebar?.togglePin() }
        overviewModel.refresh = { [weak self] in self?.manualRefresh() }
        overviewModel.settings = { [weak self] in guard let bar = self?.sidebar else { return }; bar.showMenu(nil, bar.detailSurface) }
        if sidebar?.detail.isVisible == true { updateOverview() }
        sidebar?.update(sidebarAccounts(), duration: motionDuration)
    }
}
