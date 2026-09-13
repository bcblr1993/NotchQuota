import XCTest
@testable import NotchQuota

final class MultiAccountTests: XCTestCase {
    func testGenericFilenameDiscoveryDoesNotGuessAmbiguousSources() {
        let a = URL(fileURLWithPath: "/different-user/custom/a-standalone-oauth-token")
        let b = URL(fileURLWithPath: "/different-user/custom/b-standalone-oauth-token")
        XCTAssertEqual(AntigravityDiscovery.matchingFiles(binary: Data("storage=a-standalone-oauth-token".utf8), candidates: [a,b]), [a])
        XCTAssertTrue(AntigravityDiscovery.matchingFiles(binary: Data("unknown".utf8), candidates: [a,b]).isEmpty)
        XCTAssertEqual(AntigravityDiscovery.matchingFiles(binary: Data("a-standalone-oauth-token b-standalone-oauth-token".utf8), candidates: [a,b]).count, 2)
    }
    func testTargetsKeepIndependentCacheKeysAndStableAliasChanges() {
        let a = AntigravityInstance(appPath: "/Applications/Example.app", credentialPath: "/profiles/one.json", name: "One", manual: true)
        var renamed = a; renamed.name = "Renamed"
        var b = a; b.credentialPath = "/profiles/two.json"
        XCTAssertEqual(a.id, renamed.id); XCTAssertNotEqual(a.id, b.id)
        let first = QuotaTarget(provider: .antigravity, instance: a), second = QuotaTarget(provider: .antigravity, instance: b)
        let states = [first: 20, second: 80, .antigravity: 50]
        XCTAssertEqual(states.count, 3); XCTAssertEqual(states[first], 20); XCTAssertEqual(states[second], 80)
    }
    func testCredentialParserSupportsFileAndKeychainEncoding() throws {
        let data = Data(#"{"token":{"access_token":"fixture-access","refresh_token":"fixture-refresh","expiry":"2030-01-01T00:00:00Z"}}"#.utf8)
        let direct = try GoogleCredentials.parse(data)
        let encoded = try GoogleCredentials.parse(Data(("go-keyring-base64:" + data.base64EncodedString()).utf8))
        XCTAssertEqual(direct.fingerprint, encoded.fingerprint)
        XCTAssertThrowsError(try GoogleCredentials.parse(Data(#"{"token":{"access_token":"","refresh_token":""}}"#.utf8)))
        XCTAssertThrowsError(try GoogleCredentials.parse(Data(#"{"token":{"access_token":"fixture"}}"#.utf8)))
    }
    func testIdentityDoesNotUseAvatarOrNameAsAccountKey() throws {
        let first = try AccountIdentity.parse(["sub":"one", "name":"Same", "picture":"https://lh3.googleusercontent.com/same"])
        let second = try AccountIdentity.parse(["sub":"two", "name":"Same", "picture":"https://lh3.googleusercontent.com/same"])
        XCTAssertNotEqual(first.subject, second.subject)
        XCTAssertNil(try AccountIdentity.parse(["sub":"one"]).picture)
        XCTAssertThrowsError(try AccountIdentity.parse(["name":"Missing identity"]))
    }
    func testEmailDisplayAndFallback() throws {
        let account = try AccountIdentity.parse(["sub": "stable", "name": "Same", "email": "  first@example.test\n"])
        XCTAssertEqual(account.displayName, "first@example.test")
        let renamed = try AccountIdentity.parse(["sub": "stable", "email": "second@example.test"])
        XCTAssertEqual(account.subject, renamed.subject, "Email changes must not change account identity")
        for payload: [String: Any] in [["sub": "stable", "name": "Same"], ["sub": "stable", "name": "Same", "email": "  "] , ["sub": "stable", "name": "Same", "email": 123]] {
            let fallback = try AccountIdentity.parse(payload)
            XCTAssertNil(fallback.email)
            XCTAssertEqual(fallback.displayName, "Same")
        }
        XCTAssertEqual(try AccountIdentity.parse(["sub": "stable"]).displayName, "Google 账号")
    }
    @MainActor func testEmailTitlePreservesCustomAlias() {
        let app = AppDelegate()
        app.accountNames[QuotaTarget.antigravity.id] = "first@example.test"
        XCTAssertEqual(app.displayTitle(.antigravity), "Antigravity · first@example.test")
        XCTAssertEqual(app.accountLabel(.antigravity), "first@example.test")
        app.accountAliases[QuotaTarget.antigravity.id] = "工作账号"
        XCTAssertEqual(app.displayTitle(.antigravity), "工作账号")
        XCTAssertEqual(app.accountLabel(.antigravity), "工作账号")
    }
    func testAvatarOriginValidation() {
        XCTAssertTrue(AccountAvatars.allowed(URL(string: "https://lh3.googleusercontent.com/photo")!))
        for value in ["http://lh3.googleusercontent.com/photo", "https://lh3.googleusercontent.com.attacker.test/photo", "https://example.org/photo", "https://user:password@lh3.googleusercontent.com/photo", "https://lh3.googleusercontent.com:8080/photo"] {
            XCTAssertFalse(AccountAvatars.allowed(URL(string:value)!))
        }
    }
}

private final class AccountProtocol: URLProtocol {
    static let lock = NSLock()
    static var quotaCalls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let subject = auth.contains("second") ? "subject-second" : "subject-first"
        let url = request.url!
        var value: [String: Any]
        if url.path.contains("userinfo") { value = ["sub": subject, "name": "Same display name"] }
        else if url.path.contains("loadCodeAssist") { value = ["cloudaicompanionProject": subject] }
        else {
            Self.lock.lock(); Self.quotaCalls += 1; Self.lock.unlock()
            value = ["groups": [["displayName": "Gemini", "buckets": [["displayName": "Weekly Limit Remaining", "remainingFraction": subject == "subject-first" ? 0.2 : 0.8]]]]]
        }
        let code = auth.contains("broken") ? 401 : (auth.contains("quota-failed") && !url.path.contains("userinfo") ? 503 : 200)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AccountReaderTests: XCTestCase {
    func testSeparateReadersAndAccountChangeRejectBeforeQuota() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sample.app/Contents/Resources"), withIntermediateDirectories: true)
        try Data("--cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com".utf8).write(to: root.appendingPathComponent("Sample.app/Contents/Resources/app.asar"))
        func fixture(_ name: String, access: String) throws -> AntigravityInstance {
            let file = root.appendingPathComponent(name + ".json")
            let data = try JSONSerialization.data(withJSONObject: ["token": ["access_token": access, "refresh_token": "refresh-" + access, "expiry": "2099-01-01T00:00:00Z"]])
            try data.write(to: file, options: .atomic)
            return AntigravityInstance(appPath: root.appendingPathComponent("Sample.app").path, credentialPath: file.path, name: name, manual: true)
        }
        let one = try fixture("one", access: "fixture-first"), two = try fixture("two", access: "fixture-second")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AccountProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let first = QuotaReader(googleInstance: one, session: session), second = QuotaReader(googleInstance: two, session: session)
        let a = try await first.fetch(.antigravity), b = try await second.fetch(.antigravity)
        XCTAssertEqual(a.remaining, 20); XCTAssertEqual(b.remaining, 80)
        _ = try fixture("one", access: "fixture-second")
        let before = AccountProtocol.quotaCalls
        do {
            _ = try await first.fetch(.antigravity, expectedGoogleSubject: "subject-first")
            XCTFail("Changed account must require confirmation")
        } catch QuotaError.accountChanged { }
        XCTAssertEqual(AccountProtocol.quotaCalls, before, "Do not query another account's quota before confirmation")
        let confirmed = try await first.fetch(.antigravity, expectedGoogleSubject: "subject-second")
        XCTAssertEqual(confirmed.remaining, 80)
        _ = try fixture("one", access: "fixture-broken")
        do { _ = try await first.fetch(.antigravity); XCTFail("Invalid identity must fail") }
        catch QuotaError.identityUnverified { }
        let unaffected = try await second.fetch(.antigravity)
        XCTAssertEqual(unaffected.remaining, 80)
        let unverified = await first.accountIdentity(); XCTAssertNil(unverified)
        _ = try fixture("one", access: "fixture-quota-failed")
        do { _ = try await first.fetch(.antigravity); XCTFail("Quota should fail") } catch { }
        let verified = await first.accountIdentity()
        XCTAssertEqual(verified?.subject, "subject-first", "Verified identity remains available even when quota is unavailable")
        do { _ = try await first.fetch(.antigravity, expectedGoogleSubject: "subject-second"); XCTFail("Changed account must fail") } catch QuotaError.accountChanged { }
        let changed = await first.accountIdentity(); XCTAssertNil(changed)
    }
}

final class AccountPreferenceTests: XCTestCase {
    @MainActor func testPersistenceUsesStableIDsAndPreservesDisabledDefaults() throws {
        let suite = "NotchQuota.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let instance = AntigravityInstance(appPath: "/Custom/Profile.app", credentialPath: "/Custom/credential.json", name: "Custom", manual: true)
        let first = AppDelegate()
        first.enabledInstances = [instance.id]; first.accountBindings = [instance.id: "fixture-subject"]
        first.accountAliases = [instance.id: "工作"]; first.manualInstances = [instance]
        first.saveAccountPreferences(to: defaults)
        let restarted = AppDelegate(); restarted.loadAccountPreferences(from: defaults)
        XCTAssertEqual(restarted.enabledInstances, [instance.id])
        XCTAssertEqual(restarted.accountBindings[instance.id], "fixture-subject")
        XCTAssertEqual(restarted.accountAliases[instance.id], "工作")
        XCTAssertEqual(restarted.manualInstances, [instance])
        let untouched = AppDelegate()
        XCTAssertTrue(untouched.enabledInstances.isEmpty, "Extra accounts are never enabled by default")
    }
}
