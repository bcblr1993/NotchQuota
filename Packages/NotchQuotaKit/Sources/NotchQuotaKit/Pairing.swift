import Foundation

public enum PairingError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(Int)
    case expired
    case malformed
    case decryptionFailed
    case staleBundle

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "配对数据版本 \(v) 不受支持，请更新两端应用"
        case .expired: return "二维码已过期，请在 Mac 上重新生成"
        case .malformed: return "配对数据格式不正确"
        case .decryptionFailed: return "配对密钥不匹配，请重新扫码"
        case .staleBundle: return "收到的凭据比本机的更旧，已忽略"
        }
    }
}

/// The QR code carries only a transport key, never a credential.
///
/// Credentials always travel as ciphertext through the user's own private
/// CloudKit database, so photographing the code is not enough on its own and
/// neither is reaching the iCloud data. Re-scanning issues a fresh key and
/// retires the previous one, which doubles as the recovery path after a device
/// change or a Mac reinstall.
public struct PairingEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let validity: TimeInterval = 60

    public var version: Int
    public var pairingID: UUID
    public var key: Data
    public var expires: Date

    public init(version: Int = PairingEnvelope.currentVersion, pairingID: UUID = UUID(), key: Data, expires: Date) {
        self.version = version; self.pairingID = pairingID; self.key = key; self.expires = expires.wireTruncated
    }

    public func isExpired(now: Date = Date()) -> Bool { now >= expires }

    public func validated(now: Date = Date()) throws -> PairingEnvelope {
        guard version == Self.currentVersion else { throw PairingError.unsupportedVersion(version) }
        guard key.count == PairingCrypto.keyBytes else { throw PairingError.malformed }
        guard !isExpired(now: now) else { throw PairingError.expired }
        return self
    }
}
