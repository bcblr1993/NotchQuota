import Foundation
import CryptoKit

struct AntigravityInstance: Codable, Hashable {
    var appPath: String
    var credentialPath: String?
    var name: String
    var manual = false
    var revision = ""
    var id: String { "ag:" + SHA256.hash(data: Data((URL(fileURLWithPath: appPath).standardizedFileURL.path + "|" + (credentialPath ?? "keychain")).utf8)).map { String(format: "%02x", $0) }.joined() }
    var appURL: URL { URL(fileURLWithPath: appPath) }
    var serverURL: URL { appURL.appendingPathComponent("Contents/Resources/bin/language_server") }
    var supported: Bool { credentialPath != nil }
}

struct QuotaTarget: Hashable {
    var provider: Provider
    var instance: AntigravityInstance?
    var id: String { instance?.id ?? provider.rawValue }
    static func standard(_ provider: Provider) -> Self { .init(provider: provider) }
    static let codex = standard(.codex), claude = standard(.claude), antigravity = standard(.antigravity)
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var title: String { instance?.name ?? provider.title }
}

struct AccountIdentity: Equatable {
    var subject: String
    var name: String
    var picture: URL?
    var email: String?
    var displayName: String { email ?? name }
    static func parse(_ payload: [String: Any]) throws -> Self {
        guard let subject = payload["sub"] as? String, !subject.isEmpty else { throw QuotaError.message("无法确认账号身份") }
        let name = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (payload["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(subject: subject, name: (name?.isEmpty == false ? name! : "Google 账号"), picture: (payload["picture"] as? String).flatMap(URL.init(string:)), email: email?.isEmpty == false ? email : nil)
    }
}

/// Does not read credential contents. Scans binaries only at explicit discovery time.
actor AntigravityDiscovery {
    private var cache: [String: (Date?, UInt64, [String], [String])] = [:]
    static func matchingFiles(binary: Data, candidates: [URL]) -> [URL] {
        candidates.filter { binary.range(of: Data($0.lastPathComponent.utf8)) != nil }
    }
    static func revision(_ url: URL) -> String {
        let file = url.appendingPathComponent("Contents/Resources/bin/language_server")
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        return "\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\((attrs?[.size] as? NSNumber)?.uint64Value ?? 0)"
    }
    static func isApplication(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/Resources/bin/language_server").path) else { return false }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Antigravity"
    }
    func discover(primary: URL?, manual: [AntigravityInstance], roots: [URL]? = nil, credentialRoot: URL? = nil) -> [AntigravityInstance] {
        let fm = FileManager.default
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let credentialRoot = credentialRoot ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        let candidates = ((try? fm.contentsOfDirectory(at: credentialRoot, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix("standalone-oauth-token") }
        var result = manual.filter { Self.isApplication($0.appURL) }.map { item in var updated = item; updated.revision = Self.revision(item.appURL); return updated }
        var apps = roots.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "app" }
        apps.sort { $0.path < $1.path }
        for app in apps where Self.isApplication(app) {
            guard app.resolvingSymlinksInPath() != primary?.resolvingSymlinksInPath(), !result.contains(where: { $0.appURL == app }) else { continue }
            let server = app.appendingPathComponent("Contents/Resources/bin/language_server")
            let attributes = try? fm.attributesOfItem(atPath: server.path)
            let date = attributes?[.modificationDate] as? Date, size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let paths = candidates.map(\.path).sorted()
            let matches: [String]
            if let cached = cache[app.path], cached.0 == date, cached.1 == size, cached.2 == paths { matches = cached.3 }
            else {
                let binary = (try? Data(contentsOf: server, options: .alwaysMapped)) ?? Data()
                matches = Self.matchingFiles(binary: binary, candidates: candidates).map(\.path)
                cache[app.path] = (date, size, paths, matches)
            }
            result.append(.init(appPath: app.path, credentialPath: matches.count == 1 ? matches[0] : nil, name: app.deletingPathExtension().lastPathComponent, revision: Self.revision(app)))
        }
        return result.sorted { $0.appPath < $1.appPath }
    }
}

/// Avatar requests never carry OAuth headers. Size is bounded before decoding.
actor AccountAvatars {
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".googleusercontent.com")
    }
    private var cache: [URL: (Date, Data?)] = [:]
    func data(for url: URL?) async -> Data? {
        guard let url, Self.allowed(url) else { return nil }
        if let entry = cache[url], Date().timeIntervalSince(entry.0) < 86400 { return entry.1 }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: ProviderRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var result: Data?
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 200, response.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= 1_048_576 {
                var data = Data()
                for try await byte in bytes { if data.count >= 1_048_576 { throw QuotaError.message("头像过大") }; data.append(byte) }
                result = data
            }
        } catch { result = nil }
        if cache.count >= 32 { cache.removeAll() }
        cache[url] = (Date(), result)
        return result
    }
}
