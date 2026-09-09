import AppKit
import Foundation

/// Resolve installed applications without assuming a username or /Applications location.
enum Installation {
    static func app(_ name: String) -> URL? {
        let identifiers: [String]
        switch name {
        case "Codex": identifiers = ["com.openai.codex", "com.openai.chat", "com.openai.chatgpt"]
        case "Claude": identifiers = ["com.anthropic.claudefordesktop"]
        case "Antigravity": identifiers = ["com.google.antigravity", "com.google.antigravity.ide"]
        default: identifiers = []
        }
        let names = name == "Codex" ? ["Codex", "ChatGPT"] : [name]
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots { for name in names {
            let url = root.appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        } }
        for id in identifiers { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url } }
        return nil
    }
    static func antigravityServer() throws -> URL {
        guard let app = app("Antigravity") else { throw QuotaError.message("请先安装并登录 Antigravity") }
        return app.appendingPathComponent("Contents/Resources/bin/language_server")
    }
    static func antigravityEndpoint() throws -> String {
        guard let app = app("Antigravity") else { throw QuotaError.message("请先安装并登录 Antigravity") }
        let archive = try Data(contentsOf: app.appendingPathComponent("Contents/Resources/app.asar"), options: .alwaysMapped)
        return try endpoint(from: archive)
    }
    static func endpoint(from archive: Data) throws -> String {
        let marker = Data("--cloud_code_endpoint".utf8)
        guard let position = archive.range(of: marker) else { throw QuotaError.message("当前 Antigravity 版本未提供可识别的额度地址") }
        let snippet = String(decoding: archive[position.upperBound..<min(archive.count, position.upperBound + 256)], as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "https://([a-z0-9-]+\\.googleapis\\.com)")
        guard let match = regex.firstMatch(in: snippet, range: NSRange(snippet.startIndex..., in: snippet)), let range = Range(match.range, in: snippet) else { throw QuotaError.message("无法识别 Antigravity 额度服务") }
        let endpoint = String(snippet[range])
        // Do not transmit Google credentials to arbitrary application-provided origins.
        guard ["https://cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.googleapis.com", "https://daily-cloudcode-pa.sandbox.googleapis.com"].contains(endpoint) else { throw QuotaError.message("Antigravity 额度地址尚未支持") }
        return endpoint + "/v1internal:"
    }
}
