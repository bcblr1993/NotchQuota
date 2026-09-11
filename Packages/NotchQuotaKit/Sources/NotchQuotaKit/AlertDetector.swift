import Foundation

/// Edge-triggered level held per account. Unknown readings never move it.
public enum AlertLevel: String, Codable, Sendable {
    case normal, low
}

public enum QuotaAlert: Equatable, Sendable {
    case low(accountID: String, provider: Provider, label: String, remaining: Double, reset: Date?)
    case recovered(accountID: String, provider: Provider, label: String, remaining: Double)

    public var accountID: String {
        switch self {
        case .low(let id, _, _, _, _), .recovered(let id, _, _, _): return id
        }
    }

    public var title: String {
        switch self {
        case .low(_, _, let label, _, _): return "\(label) 额度不足"
        case .recovered(_, _, let label, _): return "\(label) 额度已恢复"
        }
    }

    public var body: String {
        switch self {
        case .low(_, _, _, let remaining, let reset):
            let percent = "剩余 \(Int(remaining.rounded()))%"
            guard let reset else { return percent }
            return percent + "，" + QuotaAlert.countdown(to: reset) + "后重置"
        case .recovered(_, _, _, let remaining):
            return "剩余 \(Int(remaining.rounded()))%，可以继续使用"
        }
    }

    /// Same wording as the macOS detail footer.
    public static func countdown(to reset: Date, from now: Date = Date()) -> String {
        let seconds = max(0, reset.timeIntervalSince(now))
        if seconds > 86400 { return "\(Int(ceil(seconds / 86400))) 天" }
        if seconds > 3600 { return "\(Int(seconds / 3600)) 小时 \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) 分" }
        return "\(Int(ceil(seconds / 60))) 分钟"
    }
}

/// Hysteresis stops a reading oscillating around the low mark from alerting twice,
/// and the gap doubles as the "usable again" signal after a window resets.
///
/// A rolling window's `reset` moves on almost every poll, so a change of reset
/// time is deliberately not used as the refresh trigger.
public struct AlertDetector: Sendable {
    public var low: Double
    public var recovery: Double

    public init(low: Double = 10, recovery: Double = 25) {
        self.low = low; self.recovery = recovery
    }

    public func level(previous: AlertLevel?, remaining: Double) -> AlertLevel {
        if remaining < low { return .low }
        if remaining >= recovery { return .normal }
        return previous ?? .normal
    }

    /// Returns the level to store and the alert to deliver, if any.
    /// The first observation only records a level so a restart never re-alerts.
    public func evaluate(_ account: Account, previous: AlertLevel?, now: Date = Date()) -> (level: AlertLevel, alert: QuotaAlert?) {
        guard let remaining = account.remaining else { return (previous ?? .normal, nil) }
        let next = level(previous: previous, remaining: remaining)
        guard let previous, next != previous else { return (next, nil) }
        switch next {
        case .low:
            return (next, .low(accountID: account.id, provider: account.provider, label: account.label,
                               remaining: remaining, reset: account.snapshot?.bindingWindow?.reset))
        case .normal:
            return (next, .recovered(accountID: account.id, provider: account.provider, label: account.label,
                                     remaining: remaining))
        }
    }
}
