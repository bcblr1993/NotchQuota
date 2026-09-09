import Foundation
import CoreFoundation

enum Provider: String, CaseIterable, Codable {
    case codex, claude, antigravity
    var title: String { switch self { case .codex: return "Codex"; case .claude: return "Claude"; case .antigravity: return "Antigravity" } }
    var next: Provider { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}
/// Selection is independent of login state and whether an installed app is running.
struct ProviderSelection {
    var installed: [Provider]
    var outlineProvider: Provider? { Provider.allCases.first(where: installed.contains) }
    func selected(preferred: Provider) -> Provider? {
        installed.contains(preferred) ? preferred : installed.first
    }
    func next(after current: Provider) -> Provider? {
        guard !installed.isEmpty else { return nil }
        guard let index = installed.firstIndex(of: current) else { return installed.first }
        return installed[(index + 1) % installed.count]
    }
}
struct QuotaWindow: Identifiable, Codable {
    var id: String
    var label: String
    var remaining: Double?
    var reset: Date?
}
struct Snapshot: Codable {
    var windows: [QuotaWindow]
    var fetchedAt = Date()
    var remaining: Double? { windows.compactMap(\.remaining).min() }
}
enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
enum QuotaParser {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func percent(_ value: Any?, fraction: Bool = false, used: Bool = false) -> Double? {
        guard let n = number(value), n >= 0, n <= (fraction ? 1 : 100) else { return nil }
        return used ? 100 - n : n * (fraction ? 100 : 1)
    }
    static func date(_ value: Any?) -> Date? {
        if let n = number(value) { return Date(timeIntervalSince1970: n) }
        guard let s = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: s)
    }
    static func codex(_ data: [String: Any]) -> Snapshot {
        var rows: [QuotaWindow] = []
        func append(_ limits: [String: Any], prefix: String) {
            for key in ["primary_window", "secondary_window"] {
                guard let w = limits[key] as? [String: Any] else { continue }
                let seconds = number(w["limit_window_seconds"]) ?? 0
                let label = seconds == 604800 ? "每周" : seconds == 18000 ? "5 小时" : seconds > 0 ? "\(Int(seconds / 3600)) 小时" : (key == "primary_window" ? "当前窗口" : "长期窗口")
                rows.append(.init(id: prefix + key, label: prefix + label, remaining: percent(w["used_percent"], used: true), reset: date(w["reset_at"])))
            }
        }
        if let limits = data["rate_limit"] as? [String: Any] { append(limits, prefix: "") }
        if let extras = data["additional_rate_limits"] as? [[String: Any]] {
            for item in extras {
                if let limits = item["rate_limit"] as? [String: Any] { append(limits, prefix: (item["limit_name"] as? String ?? "附加") + " · ") }
            }
        }
        return Snapshot(windows: rows)
    }
    static func claude(_ data: [String: Any]) -> Snapshot {
        let fields = [("five_hour", "5 小时"), ("seven_day", "每周"), ("seven_day_sonnet", "Sonnet · 每周"), ("seven_day_opus", "Opus · 每周")]
        return Snapshot(windows: fields.compactMap { key, label in
            guard let w = data[key] as? [String: Any] else { return nil }
            return QuotaWindow(id: key, label: label, remaining: percent(w["utilization"], used: true), reset: date(w["resets_at"]))
        })
    }
    static func antigravity(_ data: [String: Any]) -> Snapshot {
        var rows: [QuotaWindow] = []
        let response = data["response"] as? [String: Any] ?? data
        if let groups = response["groups"] as? [[String: Any]] {
            for (gi, group) in groups.enumerated() {
                let name = group["displayName"] as? String ?? "模型组"
                for (bi, b) in ((group["buckets"] as? [[String: Any]]) ?? []).enumerated() {
                    let nested = b["remaining"] as? [String: Any]
                    let raw = b["remainingFraction"] ?? nested?["remainingFraction"]
                    let rawBucket = b["displayName"] as? String ?? b["window"] as? String ?? "额度"
                    let bucket = rawBucket.lowercased().contains("weekly") ? "每周" : rawBucket.lowercased().contains("five") ? "5 小时" : rawBucket
                    rows.append(.init(id: "\(gi)-\(bi)", label: name.replacingOccurrences(of: " Models", with: "").replacingOccurrences(of: " models", with: "").replacingOccurrences(of: "Claude and GPT", with: "Claude / GPT") + " · " + bucket, remaining: percent(raw, fraction: true), reset: date(b["resetTime"])))
                }
            }
        }
        if !rows.isEmpty { return Snapshot(windows: rows) }
        let status = data["userStatus"] as? [String: Any] ?? [:]
        let configs = status["cascadeModelConfigData"] as? [String: Any] ?? [:]
        for (i, model) in ((configs["clientModelConfigs"] as? [[String: Any]]) ?? []).enumerated() {
            guard let quota = model["quotaInfo"] as? [String: Any] else { continue }
            rows.append(.init(id: "model-\(i)", label: model["label"] as? String ?? "模型", remaining: percent(quota["remainingFraction"], fraction: true), reset: date(quota["resetTime"])))
        }
        return Snapshot(windows: rows)
    }
}
