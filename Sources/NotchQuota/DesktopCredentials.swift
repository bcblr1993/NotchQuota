import Foundation
import Security
import SQLite3
import CommonCrypto
import CryptoKit

// Reads only the Claude desktop session, never browser history or unrelated cookies.
enum ClaudeDesktopCredentials {
    struct Session { var cookie: String; var organization: String? }
    static func read() throws -> Session {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/Cookies").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw QuotaError.message("请先在 Claude 桌面版登录") }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        var statement: OpaquePointer?
        let sql = "SELECT host_key,name,value,encrypted_value,expires_utc FROM cookies WHERE host_key IN ('.claude.ai','claude.ai') AND name IN ('sessionKey','sessionKeyV3','lastActiveOrg','cf_clearance','__cf_bm','routingHint','anthropic-device-id') ORDER BY last_access_utc DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw QuotaError.message("Claude 登录存储格式已变化") }
        defer { sqlite3_finalize(statement) }
        var values: [String: String] = [:]
        var encryptionKey: Data?
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            if values[name] != nil { continue }
            let expires = sqlite3_column_int64(statement, 4)
            let now = (Date().timeIntervalSince1970 + 11644473600) * 1_000_000
            if expires > 0 && Double(expires) <= now { continue }
            let plain = String(cString: sqlite3_column_text(statement, 2))
            if !plain.isEmpty { values[name] = plain; continue }
            let count = Int(sqlite3_column_bytes(statement, 3))
            guard count > 3, let bytes = sqlite3_column_blob(statement, 3) else { continue }
            let encrypted = Data(bytes: bytes, count: count)
            guard encrypted.prefix(3) == Data("v10".utf8) else { continue }
            if encryptionKey == nil {
                let raw = try Command.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Safe Storage", "-w"], timeout: 15)
                let password = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .newlines)
                encryptionKey = try deriveKey(password)
            }
            guard let key = encryptionKey, let decoded = try? decrypt(Data(encrypted.dropFirst(3)), key: key) else { continue }
            let hash = Data(SHA256.hash(data: Data(host.utf8)))
            let data = decoded.starts(with: hash) ? Data(decoded.dropFirst(32)) : decoded
            if let value = String(data: data, encoding: .utf8), !value.contains("\n"), !value.contains("\r") { values[name] = value }
        }
        guard let session = values["sessionKey"], session.hasPrefix("sk-ant-") else { throw QuotaError.message("Claude 桌面登录已失效，请重新登录") }
        let org = values["lastActiveOrg"]
        let cookie = values.filter { $0.key != "lastActiveOrg" }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return Session(cookie: cookie, organization: org.flatMap { UUID(uuidString: $0) != nil ? $0 : nil })
    }
    static func deriveKey(_ password: String) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count, saltBytes.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16)
            }
        }
        guard status == kCCSuccess else { throw QuotaError.message("无法读取 Claude 加密登录") }
        return Data(key)
    }
    static func decrypt(_ data: Data, key: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var count = 0
        let iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { inputBytes in
                iv.withUnsafeBufferPointer { ivBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count, ivBytes.baseAddress, inputBytes.baseAddress, data.count, &output, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw QuotaError.message("Claude 登录解密失败") }
        return Data(output.prefix(count))
    }
}
