import Foundation
import Security

// Credentials stay in memory and are sent only to their original provider.
// Child command output is never logged. No credentials are passed in argv.
enum Command {
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 5) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); watchdog.cancel()
        guard process.terminationStatus == 0 else { throw QuotaError.message("本机数据读取失败") }
        return data
    }
}
final class ProviderRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}
actor QuotaReader {
    private let googleInstance: AntigravityInstance?
    private let verifyRefresh: Bool
    private var googleIdentity: AccountIdentity?
    private var identityCheckedAt: Date?
    init(googleInstance: AntigravityInstance? = nil, verifyRefresh: Bool = false, session: URLSession? = nil) {
        self.googleInstance = googleInstance; self.verifyRefresh = verifyRefresh
        self.remote = session ?? Self.makeSession()
    }
    func accountIdentity() -> AccountIdentity? { googleIdentity }
    func clearGoogleCache() { googleCredential = nil; googleSourceAccess = nil; googleProject = nil; googleIdentity = nil; identityCheckedAt = nil; googleEndpoint = nil; googleClient = nil }

    private let remote: URLSession
    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 25
        c.httpShouldSetCookies = false
        return URLSession(configuration: c, delegate: ProviderRedirectGuard(), delegateQueue: nil)
    }
    private var googleCredential: GoogleCredential?
    private var googleProject: String?
    private var googleSourceAccess: String?
    private var googleEndpoint: String?
    private var googleClient: (String, String)?
    private func json(_ data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaError.message("额度响应格式已变化") }
        return dict
    }
    private func request(_ url: String, headers: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpMethod = "POST"; req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await remote.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if CommandLine.arguments.contains("--diagnose") { print("HTTP \(req.url!.host!) \(code) \(response.mimeType ?? "unknown")") }
        guard code == 200 else {
            switch code {
            case 403 where response.mimeType == "text/html": throw QuotaError.message("服务要求网页验证，请在 Claude 中完成验证")
            case 401, 403: throw QuotaError.message("登录已过期或无权限，请在原应用重新登录")
            case 429: throw QuotaError.message("请求过于频繁，稍后自动重试")
            default: throw QuotaError.message("额度服务暂不可用（\(code)）")
            }
        }
        return try json(data)
    }
    func fetch(_ provider: Provider, expectedGoogleSubject: String? = nil) async throws -> Snapshot {
        let result: Snapshot
        switch provider {
        case .codex:
            result = try await codex()
        case .claude:
            // Desktop session is the actual Claude app account; the CLI may use a different provider.
            if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/Cookies").path) {
                let session = try ClaudeDesktopCredentials.read()
                if CommandLine.arguments.contains("--diagnose") { print("Claude source: desktop session") }
                var organization = session.organization
                let headers = ["Cookie": session.cookie, "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36", "Origin": "https://claude.ai", "Referer": "https://claude.ai/settings/usage"]
                if organization == nil {
                    var req = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    let (data, response) = try await remote.data(for: req)
                    if (response as? HTTPURLResponse)?.statusCode == 200, let orgs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], orgs.count == 1 { organization = orgs[0]["uuid"] as? String }
                }
                guard let org = organization, UUID(uuidString: org) != nil else { throw QuotaError.message("请在 Claude 桌面版选择当前组织") }
                result = QuotaParser.claude(try await request("https://claude.ai/api/organizations/\(org)/usage", headers: headers))
            } else {
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
                let data = try (try? Data(contentsOf: file)) ?? Command.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 15)
                guard let auth = try json(data)["claudeAiOauth"] as? [String: Any], let token = auth["accessToken"] as? String, !token.isEmpty else { throw QuotaError.message("请先在 Claude 登录订阅账号") }
                result = QuotaParser.claude(try await request("https://api.anthropic.com/api/oauth/usage", headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20"]))
            }
        case .antigravity:
            result = try await antigravityRemote(expectedSubject: expectedGoogleSubject)
        }
        guard result.remaining != nil else { throw QuotaError.message("服务未返回可识别的额度") }
        return result
    }
    private func codex() async throws -> Snapshot {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        for attempt in 0..<2 {
            guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")), let auth = try? json(data), let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String, !token.isEmpty else { throw QuotaError.message("请先在 Codex 登录订阅账号") }
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(tokens["account_id"] as? String, forHTTPHeaderField: "ChatGPT-Account-Id")
            let (responseData, response) = try await remote.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { try CodexSession.refresh(); continue }
            guard status == 200 else { throw QuotaError.message(status == 401 ? "Codex 登录已失效，请重新登录" : "Codex 额度服务暂不可用（\(status)）") }
            return QuotaParser.codex(try json(responseData))
        }
        throw QuotaError.message("Codex 登录续期失败")
    }
    private func antigravityRemote(expectedSubject: String?) async throws -> Snapshot {
        let source = try GoogleCredentials.read(instance: googleInstance)
        if googleCredential?.fingerprint != source.fingerprint || googleSourceAccess != source.access {
            googleCredential = source; googleSourceAccess = source.access; googleProject = nil; googleIdentity = nil; identityCheckedAt = nil
        }
        var credential = googleCredential ?? source
        if verifyRefresh || credential.expiry == nil || credential.expiry!.timeIntervalSinceNow < 60 {
            let candidates = try googleClient.map { [$0] } ?? GoogleCredentials.clientCandidates(instance: googleInstance)
            var refreshed = false
            for (id, secret) in candidates {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let form = ["client_id": id, "client_secret": secret, "refresh_token": credential.refresh, "grant_type": "refresh_token"].map { key, value in key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
                var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
                req.httpMethod = "POST"; req.httpBody = Data(form.utf8); req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await remote.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if let payload = try? json(data), let token = payload["access_token"] as? String {
                    credential.access = token; credential.expiry = Date().addingTimeInterval(QuotaParser.number(payload["expires_in"]) ?? 3600)
                    googleCredential = credential; googleClient = (id, secret); refreshed = true; break
                }
            }
            guard refreshed else { throw QuotaError.message("Antigravity 登录已过期，请重新登录") }
        }
        // Read the installed build's endpoint; production and daily are different quota pools.
        if googleEndpoint == nil {
            if let instance = googleInstance {
                let data = try Data(contentsOf: instance.appURL.appendingPathComponent("Contents/Resources/app.asar"), options: .alwaysMapped)
                googleEndpoint = try Installation.endpoint(from: data)
            } else { googleEndpoint = try Installation.antigravityEndpoint() }
        }
        let base = googleEndpoint!
        let headers = ["Authorization": "Bearer \(credential.access)", "User-Agent": "antigravity"]
        if googleIdentity == nil || Date().timeIntervalSince(identityCheckedAt ?? .distantPast) >= 3600 {
            let identity: AccountIdentity
            do { identity = try AccountIdentity.parse(await request("https://openidconnect.googleapis.com/v1/userinfo", headers: headers)) }
            catch { if googleIdentity == nil { throw QuotaError.identityUnverified }; throw error }
            if googleIdentity?.subject != identity.subject { googleProject = nil }
            googleIdentity = identity; identityCheckedAt = Date()
        }
        if let expectedSubject, googleIdentity?.subject != expectedSubject { throw QuotaError.accountChanged }
        if googleProject == nil {
            let assist = try await request(base + "loadCodeAssist", headers: headers, body: ["metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
            googleProject = assist["cloudaicompanionProject"] as? String ?? (assist["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
        }
        guard let project = googleProject, !project.isEmpty else { throw QuotaError.message("Antigravity 未返回当前账号的额度项目") }
        let response = try await request(base + "retrieveUserQuotaSummary", headers: headers, body: ["project": project])
        return QuotaParser.antigravity(response)
    }
}
