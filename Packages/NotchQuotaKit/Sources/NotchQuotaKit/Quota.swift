import Foundation

public struct QuotaWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// Percent remaining. `nil` means unknown and must never be shown as 0 or 100.
    public var remaining: Double?
    public var reset: Date?

    public init(id: String, label: String, remaining: Double? = nil, reset: Date? = nil) {
        self.id = id; self.label = label; self.remaining = remaining; self.reset = reset
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var windows: [QuotaWindow]
    public var fetchedAt: Date

    public init(windows: [QuotaWindow], fetchedAt: Date = Date()) {
        self.windows = windows; self.fetchedAt = fetchedAt
    }

    /// Lowest known remaining across windows; `nil` while every window is unknown.
    public var remaining: Double? { windows.compactMap(\.remaining).min() }

    /// The window that currently determines `remaining`, used for reset countdowns.
    public var bindingWindow: QuotaWindow? {
        windows.filter { $0.remaining != nil }.min { $0.remaining! < $1.remaining! }
    }
}

public enum QuotaError: LocalizedError, Equatable, Sendable {
    case message(String)

    public var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

/// Green above 50, amber from 20 through 50, red below 20; mirrors the macOS notch colours.
public enum QuotaLevel: String, CaseIterable, Codable, Sendable {
    case unknown, critical, warning, healthy

    public static func of(_ remaining: Double?) -> QuotaLevel {
        guard let remaining else { return .unknown }
        if remaining > 50 { return .healthy }
        if remaining >= 20 { return .warning }
        return .critical
    }
}
