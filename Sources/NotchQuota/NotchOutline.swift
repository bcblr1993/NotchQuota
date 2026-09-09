import AppKit

/// A static, click-through quota outline; no display link or repeating animation.
final class NotchOutlineView: NSView {
    var state = DisplayState()
    var hasNotch = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let points = OutlineGeometry.points(size: bounds.size, hasNotch: hasNotch)
        let value = state.snapshot?.remaining
        let color = state.stale ? NSColor.gray : QuotaTint.color(value)
        stroke(points, color: color.withAlphaComponent(value == nil || state.stale ? 0.5 : 0.22))
        if let value { stroke(OutlineGeometry.trim(points, fraction: value / 100), color: color) }
    }
    private func stroke(_ points: [CGPoint], color: NSColor) {
        guard let first = points.first, points.count > 1 else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
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
