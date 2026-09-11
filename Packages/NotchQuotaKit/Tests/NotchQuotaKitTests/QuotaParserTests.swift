import XCTest
@testable import NotchQuotaKit

/// Redacted fixtures pin the shape of each provider response. The parser must
/// keep unknown, genuinely zero and full quota apart on every platform.
final class QuotaParserTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testCodexConvertsUsedPercentToRemaining() {
        let codex = QuotaParser.codex(json(#"{"rate_limit":{"primary_window":{"used_percent":18,"limit_window_seconds":604800,"reset_at":1789435604},"secondary_window":null},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}]}"#))
        XCTAssertEqual(codex.remaining, 82)
        XCTAssertEqual(codex.windows.count, 2)
        XCTAssertEqual(codex.windows[0].label, "每周")
        XCTAssertEqual(codex.windows[1].remaining, 100, "零使用量是满额，不是未知")
        XCTAssertNotNil(codex.windows[0].reset)
    }

    func testClaudeParsesEachWindowIndependently() {
        let claude = QuotaParser.claude(json(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":40,"resets_at":"2026-09-10T18:00:00.404Z"},"seven_day_opus":null}"#))
        XCTAssertEqual(claude.remaining, 60)
        XCTAssertEqual(claude.windows[0].remaining, 100)
        XCTAssertNotNil(claude.windows[1].reset, "带毫秒的 ISO8601 也要能解析")
    }

    func testAntigravityFractionsAndLabels() {
        let anti = QuotaParser.antigravity(json(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Weekly Limit Remaining","remainingFraction":0.91447425},{"displayName":"Five Hour Limit Remaining","remainingFraction":1}]}]}"#))
        XCTAssertEqual(anti.remaining ?? 0, 91.447425, accuracy: 0.0001)
        XCTAssertEqual(anti.windows[1].label, "Gemini · 5 小时")
    }

    func testMalformedValuesNeverImpersonateQuota() {
        let unknown = QuotaParser.antigravity(json(#"{"response":{"groups":[{"buckets":[{"remaining":{}},{"remainingFraction":null},{"remainingFraction":true},{"remainingFraction":2}]}]}}"#))
        XCTAssertNil(unknown.remaining, "缺失、null、布尔值和越界比例都不算额度")
        XCTAssertNil(unknown.bindingWindow)
    }

    func testGenuinelyExhaustedStaysZero() {
        let zero = QuotaParser.antigravity(json(#"{"groups":[{"buckets":[{"remaining":{"remainingFraction":0}}]}]}"#))
        XCTAssertEqual(zero.remaining, 0, "真实耗尽必须是 0，不能退化成未知")
    }

    func testBindingWindowSkipsUnknownRows() {
        let snapshot = Snapshot(windows: [
            .init(id: "a", label: "每周", remaining: nil),
            .init(id: "b", label: "5 小时", remaining: 12, reset: Date(timeIntervalSince1970: 1_789_435_604)),
            .init(id: "c", label: "日", remaining: 80)
        ])
        XCTAssertEqual(snapshot.bindingWindow?.id, "b", "倒计时应跟随最紧的已知窗口")
        XCTAssertEqual(snapshot.remaining, 12)
    }

    func testNumberRejectsBooleansAndNonFinite() {
        XCTAssertNil(QuotaParser.number(true))
        XCTAssertNil(QuotaParser.number(Double.nan))
        XCTAssertNil(QuotaParser.number(Double.infinity))
        XCTAssertEqual(QuotaParser.number(42), 42)
    }
}

final class QuotaLevelTests: XCTestCase {
    func testThresholdsMatchTheMacNotchColours() {
        XCTAssertEqual(QuotaLevel.of(nil), .unknown)
        XCTAssertEqual(QuotaLevel.of(50), .warning, "50 属于黄色区间")
        XCTAssertEqual(QuotaLevel.of(20), .warning, "20 属于黄色区间")
        XCTAssertEqual(QuotaLevel.of(50.1), .healthy)
        XCTAssertEqual(QuotaLevel.of(19.9), .critical)
        XCTAssertEqual(QuotaLevel.of(0), .critical, "真实零额度是红色，不是未知")
    }
}
