import Foundation
import CryptoKit

struct GoogleCredential {
    var access: String
    var refresh: String
    var expiry: Date?
    var fingerprint: String { SHA256.hash(data: Data(refresh.utf8)).map { String(format: "%02x", $0) }.joined() }
}
enum GoogleCredentials {
    static func read(instance: AntigravityInstance? = nil) throws -> GoogleCredential {
        if let instance {
            guard let path = instance.credentialPath else { throw QuotaError.message("未识别此实例的登录来源，请手动添加") }
            let url = URL(fileURLWithPath: path)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw QuotaError.message("登录文件过大") }
            return try parse(data)
        }
        // Antigravity 2.x owns this entry. The older disk copy can belong to another account.
        let raw: Data
        do { raw = try Command.run("/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"], timeout: 15) }
        catch { throw QuotaError.message("请先在 Antigravity 登录，并允许读取其钥匙串") }
        return try parse(raw)
    }
    static func parse(_ raw: Data) throws -> GoogleCredential {
        let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .newlines)
        let payload: Data
        if text.hasPrefix("go-keyring-base64:"), let decoded = Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count))) { payload = decoded }
        else { payload = Data(text.utf8) }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let token = object["token"] as? [String: Any], let access = token["access_token"] as? String, let refresh = token["refresh_token"] as? String, !access.isEmpty, !refresh.isEmpty else { throw QuotaError.message("Antigravity 登录存储格式已变化") }
        return GoogleCredential(access: access, refresh: refresh, expiry: QuotaParser.date(token["expiry"]))
    }
    static func clientCandidates(instance: AntigravityInstance? = nil) throws -> [(String, String)] {
        let url = try instance?.serverURL ?? Installation.antigravityServer()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        func find(_ marker: String, before: Int, after: Int, pattern: String) throws -> [String] {
            let needle = Data(marker.utf8), regex = try NSRegularExpression(pattern: pattern)
            var values: [String] = [], offset = 0
            while offset < data.count, let range = data.range(of: needle, in: offset..<data.count) {
                let slice = data[max(0, range.lowerBound - before)..<min(data.count, range.upperBound + after)]
                let text = String(decoding: slice, as: UTF8.self)
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let r = Range(match.range, in: text) { let value = String(text[r]); if !values.contains(value) { values.append(value) } }
                }
                offset = range.upperBound
                if values.count >= 4 { break }
            }
            return values
        }
        let ids = try find(".apps.googleusercontent.com", before: 100, after: 0, pattern: "[0-9]{8,}-[a-z0-9]+\\.apps\\.googleusercontent\\.com")
        let secrets = try find("GOCSPX-", before: 0, after: 28, pattern: "GOCSPX-[A-Za-z0-9_-]{28}")
        guard !ids.isEmpty, !secrets.isEmpty else { throw QuotaError.message("无法识别当前 Antigravity 的登录配置") }
        return ids.reversed().flatMap { id in secrets.map { (id, $0) } }
    }
}
