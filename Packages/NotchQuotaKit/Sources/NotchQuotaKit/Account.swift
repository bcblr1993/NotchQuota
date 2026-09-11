import Foundation

/// One tracked account. A provider may hold several, so the identity is the
/// account id rather than the provider.
public struct Account: Identifiable, Codable, Equatable, Sendable {
    /// Ten minutes matches the macOS app's staleness rule.
    public static let staleAfter: TimeInterval = 600

    public var id: String
    public var provider: Provider
    public var label: String
    public var snapshot: Snapshot?
    public var error: String?

    public init(id: String, provider: Provider, label: String, snapshot: Snapshot? = nil, error: String? = nil) {
        self.id = id; self.provider = provider; self.label = label; self.snapshot = snapshot; self.error = error
    }

    public var remaining: Double? { snapshot?.remaining }
    public var level: QuotaLevel { QuotaLevel.of(remaining) }

    /// A reading kept from an earlier fetch. Shown greyed out rather than dropped.
    public func isStale(now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        return error != nil || now.timeIntervalSince(snapshot.fetchedAt) > Self.staleAfter
    }
}

/// Ordering shown in the aggregate list and the widget: provider priority first,
/// then the user's label, so the layout does not jump between refreshes.
public enum AccountOrder {
    public static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.sorted { a, b in
            let left = Provider.allCases.firstIndex(of: a.provider) ?? 0
            let right = Provider.allCases.firstIndex(of: b.provider) ?? 0
            if left != right { return left < right }
            if a.label != b.label { return a.label.localizedStandardCompare(b.label) == .orderedAscending }
            return a.id < b.id
        }
    }
}
