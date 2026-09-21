import AppKit
import QuartzCore

/// Stable persisted values; unknown values from future versions fall back safely.
enum SidebarAppearance: String, CaseIterable {
    case capsule, orb, gauge, ghost
    static let preferenceKey = "sidebarAppearance"
    static func restored(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .capsule }
    var scale: CGFloat { self == .ghost ? 2.25 : 1.5 }
    var title: String {
        switch self {
        case .capsule: return "原生胶囊"
        case .orb: return "磨砂圆球"
        case .gauge: return "迷你仪表"
        case .ghost: return "小幽灵"
        }
    }
}

/// Only the selected design is allocated. Gradients are static layers, not live blur or shaders.
final class SidebarEmblem: CALayer {
    private let indicator = CAShapeLayer(), valueLabel = CATextLayer(), eyes = CALayer()
    private(set) var appearance: SidebarAppearance = .capsule
    override init() { super.init(); bounds = CGRect(x: 0, y: 0, width: 36, height: 36) }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ style: SidebarAppearance) {
        stopMotion()
        sublayers?.forEach { $0.removeFromSuperlayer() }
        eyes.sublayers?.forEach { $0.removeFromSuperlayer() }
        appearance = style
        indicator.path = nil; indicator.fillColor = nil; indicator.strokeColor = nil
        indicator.lineWidth = 2; indicator.lineCap = .round; indicator.strokeEnd = 1
        indicator.frame = bounds
        valueLabel.frame = CGRect(x: 1, y: 5, width: 34, height: 10)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        valueLabel.fontSize = 8; valueLabel.alignmentMode = .center
        valueLabel.foregroundColor = NSColor.white.cgColor
        let dark = [NSColor(white: 0.23, alpha: 1), NSColor(red: 0.06, green: 0.075, blue: 0.10, alpha: 1)]
        switch style {
        case .capsule:
            body(CGPath(roundedRect: CGRect(x: 7, y: 1, width: 22, height: 34), cornerWidth: 11, cornerHeight: 11, transform: nil), colors: dark)
            indicator.path = CGPath(roundedRect: CGRect(x: 16.5, y: 19, width: 3, height: 11), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            valueLabel.frame.origin.y = 7
            addSublayer(valueLabel)
        case .orb:
            body(CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 32, height: 32), transform: nil), colors: [NSColor(red: 0.91, green: 0.94, blue: 1, alpha: 0.98), NSColor(red: 0.58, green: 0.65, blue: 0.81, alpha: 0.95), NSColor(red: 0.79, green: 0.83, blue: 0.94, alpha: 0.98)])
            let shine = CAGradientLayer(); shine.frame = CGRect(x: 8, y: 21, width: 15, height: 9)
            shine.colors = [NSColor(white: 1, alpha: 0.7).cgColor, NSColor(white: 1, alpha: 0).cgColor]
            shine.cornerRadius = 4.5; addSublayer(shine)
            indicator.path = CGPath(ellipseIn: CGRect(x: 15, y: 14, width: 6, height: 6), transform: nil)
        case .gauge:
            body(CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 34, height: 34), transform: nil), colors: dark)
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: 18, y: 19), radius: 12, startAngle: -.pi * 0.22, endAngle: .pi * 1.22, clockwise: false)
            let track = CAShapeLayer(); track.path = arc; track.fillColor = nil
            track.strokeColor = NSColor(white: 1, alpha: 0.13).cgColor; track.lineWidth = 2; track.lineCap = .round
            addSublayer(track); indicator.path = arc
            let spark = CGMutablePath()
            spark.move(to: CGPoint(x: 18, y: 26)); spark.addLine(to: CGPoint(x: 20, y: 22))
            spark.addLine(to: CGPoint(x: 24, y: 20)); spark.addLine(to: CGPoint(x: 20, y: 18))
            spark.addLine(to: CGPoint(x: 18, y: 14)); spark.addLine(to: CGPoint(x: 16, y: 18))
            spark.addLine(to: CGPoint(x: 12, y: 20)); spark.addLine(to: CGPoint(x: 16, y: 22)); spark.closeSubpath()
            let mark = CAShapeLayer(); mark.path = spark; mark.fillColor = NSColor(white: 0.96, alpha: 1).cgColor
            addSublayer(mark); addSublayer(valueLabel)
        case .ghost:
            let p = CGMutablePath(); p.move(to: CGPoint(x: 5, y: 17))
            p.addCurve(to: CGPoint(x: 30, y: 17), control1: CGPoint(x: 3, y: 39), control2: CGPoint(x: 32, y: 39))
            p.addLine(to: CGPoint(x: 31, y: 6))
            p.addCurve(to: CGPoint(x: 23, y: 5), control1: CGPoint(x: 31, y: 1), control2: CGPoint(x: 25, y: 1))
            p.addCurve(to: CGPoint(x: 15, y: 5), control1: CGPoint(x: 21, y: 1), control2: CGPoint(x: 17, y: 1))
            p.addCurve(to: CGPoint(x: 5, y: 6), control1: CGPoint(x: 10, y: 1), control2: CGPoint(x: 3, y: 1))
            p.closeSubpath()
            body(p, colors: [NSColor(red: 1, green: 0.98, blue: 0.93, alpha: 1), NSColor(red: 0.80, green: 0.80, blue: 0.84, alpha: 1)])
            eyes.frame = CGRect(x: 9, y: 18, width: 14, height: 7)
            for x: CGFloat in [1, 9] {
                let eye = CAShapeLayer(); eye.path = CGPath(ellipseIn: CGRect(x: x, y: 0, width: 3.5, height: 6), transform: nil)
                eye.fillColor = NSColor(white: 0.16, alpha: 1).cgColor; eyes.addSublayer(eye)
            }
            addSublayer(eyes)
            // Lean the body and face out into the desktop from the screen edge.
            let leaningBody = CALayer()
            leaningBody.bounds = bounds
            leaningBody.anchorPoint = CGPoint(x: 27.0 / 36, y: 13.0 / 36)
            leaningBody.position = CGPoint(x: 27, y: 13)
            let bodyLayers = sublayers ?? []
            for child in bodyLayers { child.removeFromSuperlayer(); leaningBody.addSublayer(child) }
            leaningBody.transform = CATransform3DMakeRotation(14 * .pi / 180, 0, 0, 1)
            addSublayer(leaningBody)
        }
        if style != .ghost { addSublayer(indicator) }
    }
    private func body(_ path: CGPath, colors: [NSColor]) {
        let gradient = CAGradientLayer(); gradient.frame = bounds
        gradient.colors = colors.map(\.cgColor); gradient.startPoint = CGPoint(x: 0.2, y: 1); gradient.endPoint = CGPoint(x: 0.8, y: 0)
        let mask = CAShapeLayer(); mask.path = path; gradient.mask = mask; addSublayer(gradient)
        let rim = CAShapeLayer(); rim.path = path; rim.fillColor = nil
        rim.strokeColor = NSColor(white: 1, alpha: 0.25).cgColor; rim.lineWidth = 0.6; addSublayer(rim)
    }
    func update(remaining: Double?, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let color = QuotaTint.color(remaining).cgColor
        indicator.fillColor = appearance == .gauge ? nil : color
        indicator.strokeColor = appearance == .gauge ? color : nil
        indicator.strokeEnd = appearance == .gauge ? CGFloat(min(100, max(0, remaining ?? 0))) / 100 : 1
        valueLabel.contentsScale = scale * appearance.scale
        valueLabel.string = remaining.map { "\(Int($0.rounded()))%" } ?? "—"
        CATransaction.commit()
    }
    func stopMotion() { removeAllAnimations(); eyes.removeAllAnimations() }
    var hasMotion: Bool { animationKeys()?.isEmpty == false || eyes.animationKeys()?.isEmpty == false }
    func idle(_ enabled: Bool) {
        guard enabled else { removeAnimation(forKey: "idleFloat"); eyes.removeAllAnimations(); return }
        guard animation(forKey: "idleFloat") == nil else { return }
        let float = CAKeyframeAnimation(keyPath: "transform.translation.y")
        float.values = [0, 0, appearance == .ghost ? 1.8 : 0.8, 0, 0]
        float.keyTimes = [0, 0.70, 0.84, 0.96, 1]; float.duration = 10
        float.repeatCount = .infinity; float.calculationMode = .cubic; add(float, forKey: "idleFloat")
        if appearance == .ghost {
            let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
            blink.values = [1, 1, 0.12, 1, 1]; blink.keyTimes = [0, 0.8, 0.82, 0.85, 1]
            blink.duration = 7; blink.repeatCount = .infinity; eyes.add(blink, forKey: "blink")
        }
    }
    func face(right: Bool, docked: Bool, peeking: Bool) {
        // Mirror only the character, never quota text.
        sublayerTransform = CATransform3DMakeScale((appearance == .ghost && !right ? -1 : 1) * appearance.scale, appearance.scale, 1)
    }
}
