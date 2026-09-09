import Foundation
import CFNetwork

// Runs the credential owner's refresh protocol only after an expired access token.
// No thread is created, no model request is made, and no account output is logged.
enum CodexSession {
    static func refresh(force: Bool = true) throws {
        let paths = [Installation.app("Codex")?.appendingPathComponent("Contents/Resources/codex").path ?? "", "/opt/homebrew/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        guard let binary = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw QuotaError.message("Codex 登录已过期，请重新登录") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any], (proxy["HTTPSEnable"] as? Int) == 1, let host = proxy["HTTPSProxy"] as? String, let port = proxy["HTTPSPort"] as? Int {
            environment["HTTPS_PROXY"] = "http://\(host):\(port)"; environment["HTTP_PROXY"] = "http://\(host):\(port)"
        }
        process.environment = environment
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
        defer {
            deadline.cancel(); try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "notchquota", "version": "0.1.0"]]])
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw QuotaError.message("Codex 登录续期失败，请重新登录") }
            pending.append(chunk)
            guard pending.count < 1_048_576 else { throw QuotaError.message("Codex 登录服务响应异常") }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                guard object["error"] == nil else { throw QuotaError.message("Codex 登录续期失败，请重新登录") }
                if id == 0 {
                    try send(["method": "initialized"])
                    try send(["id": 1, "method": "account/read", "params": ["refreshToken": force]])
                } else if id == 1 {
                    guard let result = object["result"] as? [String: Any], let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else { throw QuotaError.message("请先在 Codex 登录订阅账号") }
                    return
                }
            }
        }
    }
}
