import CryptoKit
import Foundation

/// AES-GCM sealing shared by the Mac exporter and the iOS importer.
///
/// CryptoKit is hardware accelerated on both platforms and adds no binary
/// weight to the widget extension.
public enum PairingCrypto {
    public static let keyBytes = 32

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    public static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == keyBytes else { throw PairingError.malformed }
        return SymmetricKey(data: data)
    }

    /// Both ends pin the date strategy so a bundle sealed by one decodes on the other.
    ///
    /// Whole milliseconds as an integer, not a `Double` and not ISO8601: JSON
    /// `Double` round trips are not bit exact (the text looks identical while the
    /// last bits differ) and the ISO8601 text form drops sub-second precision
    /// entirely. Exact equality matters twice over — `CredentialBundle.supersedes`
    /// compares `issued` to reject a replayed bundle, and the phone compares a
    /// freshly decrypted bundle against the stored one to avoid rewriting the
    /// keychain and burning a widget reload when nothing changed.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.wireMilliseconds)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            Date(wireMilliseconds: try decoder.singleValueContainer().decode(Int64.self))
        }
        return decoder
    }

    public static func seal<T: Encodable>(_ value: T, with key: SymmetricKey) throws -> Data {
        let plain = try encoder().encode(value)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw PairingError.malformed }
        return combined
    }

    public static func open<T: Decodable>(_ type: T.Type, from data: Data, with key: SymmetricKey) throws -> T {
        guard let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key) else {
            throw PairingError.decryptionFailed
        }
        guard let value = try? decoder().decode(type, from: plain) else { throw PairingError.malformed }
        return value
    }
}

public extension PairingEnvelope {
    /// Compact base64url so the payload stays well inside a QR code's capacity.
    func qrPayload() throws -> String {
        let data = try PairingCrypto.encoder().encode(self)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func from(qrPayload: String, now: Date = Date()) throws -> PairingEnvelope {
        var text = qrPayload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { throw PairingError.malformed }
        guard let envelope = try? PairingCrypto.decoder().decode(PairingEnvelope.self, from: data) else { throw PairingError.malformed }
        return try envelope.validated(now: now)
    }

    static func issue(now: Date = Date()) -> (envelope: PairingEnvelope, key: SymmetricKey) {
        let key = PairingCrypto.newKey()
        let envelope = PairingEnvelope(key: PairingCrypto.keyData(key), expires: now.addingTimeInterval(validity))
        return (envelope, key)
    }
}
