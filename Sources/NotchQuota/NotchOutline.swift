import AppKit
import QuartzCore

/// One compositor opacity animation; pixels are redrawn only when quota/layout changes.
final class NotchOutlineView: NSView {
    var state = DisplayState()
    var hasNotch = true
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setBreathing(active: Bool, reducedMotion: Bool, lowPower: Bool) {
        guard active, !reducedMotion, !lowPower, state.snapshot?.remaining != nil, !state.stale else {
            layer?.removeAnimation(forKey: "breathing")
            return
        }
        guard layer?.animation(forKey: "breathing") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.62; pulse.toValue = 1.0
        pulse.duration = 2.4; pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: "breathing")
    }
    var isBreathing: Bool { layer?.animation(forKey: "breathing") != nil }

    override func draw(_ dirtyRect: NSRect) {
        let points = OutlineGeometry.points(size: bounds.size, hasNotch: hasNotch)
        let value = state.snapshot?.remaining
        let color: NSColor
        if value == nil || state.stale { color = .gray }
        else if value! > 50 { color = NSColor(srgbRed: 0.12, green: 1, blue: 0.52, alpha: 1) }
        else if value! >= 20 { color = NSColor(srgbRed: 1, green: 0.8, blue: 0.10, alpha: 1) }
        else { color = NSColor(srgbRed: 1, green: 0.24, blue: 0.29, alpha: 1) }
        // A dark underlay keeps the saturated core readable against bright wallpapers.
        stroke(points, color: NSColor.black.withAlphaComponent(0.3), width: 3.2)
        stroke(points, color: color.withAlphaComponent(value == nil || state.stale ? 0.65 : 0.32), width: 2)
        if let value {
            let remaining = OutlineGeometry.trim(points, fraction: value / 100)
            stroke(remaining, color: color.withAlphaComponent(0.25), width: 4.5)
            stroke(remaining, color: color, width: 2.1)
        }
    }
    private func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first, points.count > 1 else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    }
}

enum OutlineGeometry {
    static func points(size: CGSize, hasNotch: Bool) -> [CGPoint] {
        guard hasNotch else { return [CGPoint(x: 2, y: 2), CGPoint(x: size.width - 2, y: 2)] }
        let left: CGFloat = 1.5, right = size.width - 1.5, bottom = size.height - 1.5
        let radius = min(9, bottom / 2)
        var points = [CGPoint(x: left, y: 0), CGPoint(x: left, y: bottom - radius)]
        for i in 0...16 {
            let angle = CGFloat.pi - CGFloat(i) / 16 * .pi / 2
            points.append(CGPoint(x: left + radius + cos(angle) * radius, y: bottom - radius + sin(angle) * radius))
        }
        points.append(CGPoint(x: right - radius, y: bottom))
        for i in 0...16 {
            let angle = CGFloat.pi / 2 - CGFloat(i) / 16 * .pi / 2
            points.append(CGPoint(x: right - radius + cos(angle) * radius, y: bottom - radius + sin(angle) * radius))
        }
        points.append(CGPoint(x: right, y: 0))
        return points
    }
    static func trim(_ points: [CGPoint], fraction: Double) -> [CGPoint] {
        guard let first = points.first, fraction.isFinite, fraction > 0 else { return [] }
        if fraction >= 1 { return points }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) * fraction
        var result = [first]
        for (index, length) in lengths.enumerated() where length > 0 {
            let a = points[index], b = points[index + 1]
            if remaining >= length { result.append(b); remaining -= length }
            else {
                let ratio = remaining / length
                result.append(CGPoint(x: a.x + (b.x - a.x) * ratio, y: a.y + (b.y - a.y) * ratio))
                break
            }
        }
        return result
    }
}
