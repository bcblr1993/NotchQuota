import CryptoKit
import XCTest
@testable import NotchQuotaKit

final class PairingTests: XCTestCase {
    private func bundle(issued: Date = Date()) -> CredentialBundle {
        CredentialBundle(issued: issued, accounts: [
            .init(id: "codex-work", provider: .codex, label: "工作 ChatGPT",
                  secret: .codex(access: "token-a", chatgptAccountID: "acct-1", expires: issued.addingTimeInterval(864_000))),
            .init(id: "anti-main", provider: .antigravity, label: "Antigravity",
                  secret: .google(access: "token-b", refresh: "refresh-b", expires: issued.addingTimeInterval(3600),
                                  clientID: "id.apps.googleusercontent.com", clientSecret: "GOCSPX-secret",
                                  endpoint: "https://cloudcode-pa.googleapis.com/v1internal:"))
        ])
    }

    func testEnvelopeSurvivesQRRoundTrip() throws {
        let (envelope, _) = PairingEnvelope.issue()
        let restored = try PairingEnvelope.from(qrPayload: envelope.qrPayload())
        XCTAssertEqual(restored, envelope)
    }

    /// A sealed bundle must decode back into something `==` to itself.
    ///
    /// JSON `Double` round trips are not bit exact, so encoding dates as seconds
    /// silently produced unequal values whose descriptions looked identical.
    /// Repeated live `Date()` values are what exposes it — a single hand-written
    /// constant happens to survive.
    func testDecodedBundleEqualsTheSealedOne() throws {
        let key = PairingCrypto.newKey()
        for _ in 0..<50 {
            let original = bundle()
            let opened = try PairingCrypto.open(CredentialBundle.self, from: PairingCrypto.seal(original, with: key), with: key)
            XCTAssertEqual(opened, original, "相等性不稳定会导致每次同步都重写钥匙串并浪费 widget 刷新配额")
            XCTAssertFalse(opened.supersedes(original), "同一份不应被当成更新的版本")
        }
    }

    func testSubSecondOrderingSurvivesEncoding() throws {
        let key = PairingCrypto.newKey()
        let issued = Date()
        let sealed = try PairingCrypto.seal(bundle(issued: issued), with: key)
        let opened = try PairingCrypto.open(CredentialBundle.self, from: sealed, with: key)
        XCTAssertTrue(opened.supersedes(bundle(issued: issued.addingTimeInterval(-0.002))), "同一秒内的先后顺序不能被编码抹平")
    }

    func testWireDateTruncationIsIdempotent() {
        for _ in 0..<50 {
            let once = Date().wireTruncated
            XCTAssertEqual(once.wireTruncated, once)
            XCTAssertEqual(Date(wireMilliseconds: once.wireMilliseconds), once)
        }
    }

    func testQRPayloadStaysWellInsideQRCapacity() throws {
        let (envelope, _) = PairingEnvelope.issue()
        // Version 40-L holds about 2953 bytes; the envelope must not approach it.
        XCTAssertLessThan(try envelope.qrPayload().count, 400)
    }

    func testEnvelopeExpiresAfterOneMinute() {
        let now = Date()
        let (envelope, _) = PairingEnvelope.issue(now: now)
        XCTAssertNoThrow(try envelope.validated(now: now.addingTimeInterval(59)))
        XCTAssertThrowsError(try envelope.validated(now: now.addingTimeInterval(61))) {
            XCTAssertEqual($0 as? PairingError, .expired)
        }
    }

    func testEnvelopeRejectsUnknownVersionAndBadKeyLength() {
        let future = PairingEnvelope(version: 99, key: Data(repeating: 1, count: 32), expires: Date().addingTimeInterval(60))
        XCTAssertThrowsError(try future.validated()) {
            XCTAssertEqual($0 as? PairingError, .unsupportedVersion(99))
        }
        let short = PairingEnvelope(key: Data(repeating: 1, count: 16), expires: Date().addingTimeInterval(60))
        XCTAssertThrowsError(try short.validated()) {
            XCTAssertEqual($0 as? PairingError, .malformed)
        }
    }

    func testGarbageQRPayloadIsRejected() {
        XCTAssertThrowsError(try PairingEnvelope.from(qrPayload: "not-base64-@@@"))
        XCTAssertThrowsError(try PairingEnvelope.from(qrPayload: ""))
    }

    func testSealedBundleRoundTripsWithTheMatchingKey() throws {
        let key = PairingCrypto.newKey()
        let sealed = try PairingCrypto.seal(bundle(), with: key)
        let opened = try PairingCrypto.open(CredentialBundle.self, from: sealed, with: key)
        XCTAssertEqual(opened.accounts.count, 2)
        XCTAssertEqual(opened.accounts[0].secret, bundle(issued: opened.issued).accounts[0].secret)
    }

    func testCiphertextLeaksNoPlaintext() throws {
        let key = PairingCrypto.newKey()
        let sealed = try PairingCrypto.seal(bundle(), with: key)
        let blob = String(decoding: sealed, as: UTF8.self)
        for secret in ["token-a", "refresh-b", "GOCSPX-secret", "工作 ChatGPT"] {
            XCTAssertFalse(blob.contains(secret), "密文中不得出现明文 \(secret)")
            XCTAssertFalse(sealed.range(of: Data(secret.utf8)) != nil, "字节层面也不得出现 \(secret)")
        }
    }

    func testWrongKeyFailsClosed() throws {
        let sealed = try PairingCrypto.seal(bundle(), with: PairingCrypto.newKey())
        XCTAssertThrowsError(try PairingCrypto.open(CredentialBundle.self, from: sealed, with: PairingCrypto.newKey())) {
            XCTAssertEqual($0 as? PairingError, .decryptionFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let key = PairingCrypto.newKey()
        var sealed = try PairingCrypto.seal(bundle(), with: key)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try PairingCrypto.open(CredentialBundle.self, from: sealed, with: key)) {
            XCTAssertEqual($0 as? PairingError, .decryptionFailed, "GCM 认证标签必须拦下篡改")
        }
    }

    func testKeyDataRoundTripAndLengthGuard() throws {
        let key = PairingCrypto.newKey()
        let data = PairingCrypto.keyData(key)
        XCTAssertEqual(data.count, PairingCrypto.keyBytes)
        XCTAssertEqual(PairingCrypto.keyData(try PairingCrypto.key(from: data)), data)
        XCTAssertThrowsError(try PairingCrypto.key(from: Data(repeating: 0, count: 31)))
    }

    func testBundleRejectsRollback() {
        let now = Date()
        let current = bundle(issued: now)
        XCTAssertTrue(current.supersedes(nil))
        XCTAssertTrue(bundle(issued: now.addingTimeInterval(1)).supersedes(current))
        XCTAssertFalse(bundle(issued: now.addingTimeInterval(-1)).supersedes(current), "重放旧凭据必须被忽略")
        XCTAssertFalse(current.supersedes(current), "同一份不重复应用")
    }

    func testBundleVersionGate() {
        var old = bundle()
        old.version = 0
        XCTAssertThrowsError(try old.validated()) {
            XCTAssertEqual($0 as? PairingError, .unsupportedVersion(0))
        }
        XCTAssertNoThrow(try bundle().validated())
    }
}

final class ProviderSecretTests: XCTestCase {
    func testOnlyTheMacCanRenewCodex() {
        let codex = ProviderSecret.codex(access: "a", chatgptAccountID: nil, expires: nil)
        XCTAssertFalse(codex.renewableOnDevice, "手机不得自行续期 Codex，避免冒用官方客户端")
        XCTAssertTrue(ProviderSecret.google(access: "a", refresh: "r", expires: nil, clientID: "c", clientSecret: "s", endpoint: "e").renewableOnDevice)
        XCTAssertTrue(ProviderSecret.claudeOAuth(access: "a", refresh: "r", expires: nil).renewableOnDevice)
        XCTAssertFalse(ProviderSecret.claudeOAuth(access: "a", refresh: nil, expires: nil).renewableOnDevice)
    }

    func testExpiryUsesSafetyMargin() {
        let now = Date()
        let secret = ProviderSecret.codex(access: "a", chatgptAccountID: nil, expires: now.addingTimeInterval(30))
        XCTAssertTrue(secret.isExpired(now: now), "30 秒后过期视为已过期，留出续期余量")
        XCTAssertFalse(ProviderSecret.codex(access: "a", chatgptAccountID: nil, expires: now.addingTimeInterval(600)).isExpired(now: now))
        XCTAssertFalse(ProviderSecret.codex(access: "a", chatgptAccountID: nil, expires: nil).isExpired(now: now), "没有过期时间就不主动判过期")
    }

    func testProviderMapping() {
        XCTAssertEqual(ProviderSecret.codex(access: "a", chatgptAccountID: nil, expires: nil).provider, .codex)
        XCTAssertEqual(ProviderSecret.claudeOAuth(access: "a", refresh: nil, expires: nil).provider, .claude)
        XCTAssertEqual(ProviderSecret.google(access: "a", refresh: "r", expires: nil, clientID: "c", clientSecret: "s", endpoint: "e").provider, .antigravity)
    }
}
