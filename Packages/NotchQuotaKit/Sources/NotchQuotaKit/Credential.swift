import Foundation

/// What the iPhone needs to query one account on its own.
///
/// Codex carries no refresh material on purpose: its access token lives about
/// ten days and only the official CLI on the Mac is allowed to renew it, so the
/// phone never has to impersonate an OAuth client.
public enum ProviderSecret: Codable, Equatable, Sendable {
    case codex(access: String, chatgptAccountID: String?, expires: Date?)
    case claudeOAuth(access: String, refresh: String?, expires: Date?)
    case google(access: String, refresh: String, expires: Date?, clientID: String, clientSecret: String, endpoint: String)

    public var provider: Provider {
        switch self {
        case .codex: return .codex
        case .claudeOAuth: return .claude
        case .google: return .antigravity
        }
    }

    public var expires: Date? {
        switch self {
        case .codex(_, _, let expires), .claudeOAuth(_, _, let expires), .google(_, _, let expires, _, _, _): return expires
        }
    }

    /// True when only the Mac can produce a working token again.
    public var renewableOnDevice: Bool {
        switch self {
        case .google: return true
        case .claudeOAuth(_, let refresh, _): return refresh != nil
        case .codex: return false
        }
    }

    /// Counted as expired a minute early so a refresh happens before a request fails.
    public func isExpired(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expires else { return false }
        return expires.timeIntervalSince(now) <= margin
    }

    /// Normalised to the wire's millisecond resolution; see `Date.wireTruncated`.
    var wireTruncated: ProviderSecret {
        switch self {
        case .codex(let access, let accountID, let expires):
            return .codex(access: access, chatgptAccountID: accountID, expires: expires?.wireTruncated)
        case .claudeOAuth(let access, let refresh, let expires):
            return .claudeOAuth(access: access, refresh: refresh, expires: expires?.wireTruncated)
        case .google(let access, let refresh, let expires, let clientID, let clientSecret, let endpoint):
            return .google(access: access, refresh: refresh, expires: expires?.wireTruncated,
                           clientID: clientID, clientSecret: clientSecret, endpoint: endpoint)
        }
    }
}

public struct AccountCredential: Identifiable, Codable, Equatable, Sendable {
    /// Stable across re-pairings so relabelling and widget choices survive.
    public var id: String
    public var provider: Provider
    public var label: String
    public var secret: ProviderSecret

    public init(id: String, provider: Provider, label: String, secret: ProviderSecret) {
        self.id = id; self.provider = provider; self.label = label; self.secret = secret.wireTruncated
    }
}

public struct CredentialBundle: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var issued: Date
    public var accounts: [AccountCredential]

    public init(version: Int = CredentialBundle.currentVersion, issued: Date = Date(), accounts: [AccountCredential]) {
        self.version = version; self.issued = issued.wireTruncated; self.accounts = accounts
    }

    /// Blocks rollback to an older bundle replayed from CloudKit history.
    public func supersedes(_ other: CredentialBundle?) -> Bool {
        guard let other else { return true }
        return issued > other.issued
    }

    public func validated() throws -> CredentialBundle {
        guard version == Self.currentVersion else { throw PairingError.unsupportedVersion(version) }
        return self
    }
}
