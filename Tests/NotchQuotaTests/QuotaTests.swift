import XCTest
@testable import NotchQuota

final class QuotaTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any] }
    func testQuotaParsingAndIdleBoundaries() {
        let codex = QuotaParser.codex(json(#"{"rate_limit":{"primary_window":{"used_percent":18,"limit_window_seconds":604800,"reset_at":1789435604},"secondary_window":null},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000}}}]}"#))
        XCTAssert(codex.remaining == 82, "Codex 使用比例转换为剩余比例")
        XCTAssert(codex.windows[0].label == "每周", "Codex 单周窗口不误标五小时")
        XCTAssert(codex.windows.count == 2 && codex.windows[1].remaining == 100, "额外模型限额与零使用量")
        let claude = QuotaParser.claude(json(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":40,"resets_at":"2026-09-10T18:00:00.404Z"},"seven_day_opus":null}"#))
        XCTAssert(claude.remaining == 60 && claude.windows[0].remaining == 100, "Claude session/weekly 独立解析")
        XCTAssert(claude.windows[1].reset != nil, "带毫秒的重置时间")
        let anti = QuotaParser.antigravity(json(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Weekly Limit Remaining","remainingFraction":0.91447425},{"displayName":"Five Hour Limit Remaining","remainingFraction":1}]}]}"#))
        XCTAssert(abs((anti.remaining ?? 0) - 91.447425) < 0.0001, "Antigravity 直接远程响应比例")
        XCTAssert(anti.windows[1].label == "Gemini · 5 小时", "Antigravity 紧凑中文周期")
        let unknown = QuotaParser.antigravity(json(#"{"response":{"groups":[{"buckets":[{"remaining":{}},{"remainingFraction":null},{"remainingFraction":true},{"remainingFraction":2}]}]}}"#))
        XCTAssert(unknown.remaining == nil, "缺失、null、布尔值和非法比例均不冒充额度")
        let zero = QuotaParser.antigravity(json(#"{"groups":[{"buckets":[{"remaining":{"remainingFraction":0}}]}]}"#))
        XCTAssert(zero.remaining == 0, "真实耗尽保持为零")
        XCTAssert(QuotaTint.color(50) == QuotaTint.color(20), "黄色区间包含 20 和 50")
        XCTAssert(QuotaTint.color(19) != QuotaTint.color(20) && QuotaTint.color(51) != QuotaTint.color(50), "红黄绿边界")
        var idle = IdleState(); idle.interact(at: 100)
        XCTAssert(!idle.tick(at: 114.99), "15 秒之前保持显示")
        XCTAssert(idle.tick(at: 115) && !idle.visible, "15 秒时隐藏")
        XCTAssert(!idle.tick(at: 130), "隐藏后不会自行显示")
        idle.interact(at: 131); XCTAssert(idle.visible && !idle.tick(at: 145), "再次操作重新计时")
        XCTAssert(idle.tick(at: 146), "重新操作后完整 15 秒")
        XCTAssert(Provider.codex.next.next.next == .codex, "三图标循环")
        let stale = DisplayState(snapshot: Snapshot(windows: codex.windows, fetchedAt: Date().addingTimeInterval(-601)))
        XCTAssert(stale.stale, "旧读数有过期标记")
    }
}

final class EndpointTests: XCTestCase {
    func testUsesInstalledEndpointRatherThanOtherQuotaPool() throws {
        let sample = Data("['--cloud_code_endpoint', 'https://daily-cloudcode-pa.googleapis.com']".utf8)
        XCTAssertEqual(try Installation.endpoint(from: sample), "https://daily-cloudcode-pa.googleapis.com/v1internal:")
    }
    func testUntrustedOrMissingEndpointIsRejected() {
        XCTAssertThrowsError(try Installation.endpoint(from: Data("--cloud_code_endpoint https://attacker.googleapis.com".utf8)))
        XCTAssertThrowsError(try Installation.endpoint(from: Data("--cloud_code_endpoint https://example.com".utf8)))
        XCTAssertThrowsError(try Installation.endpoint(from: Data()))
    }
}

final class ProviderSelectionTests: XCTestCase {
    func testAllInstallationCombinations() {
        for mask in 0..<8 {
            let available = Provider.allCases.enumerated().compactMap { index, provider in
                mask & (1 << index) != 0 ? provider : nil
            }
            let selection = ProviderSelection(installed: available)
            for preferred in Provider.allCases {
                XCTAssertEqual(selection.selected(preferred: preferred), available.contains(preferred) ? preferred : available.first)
                if available.isEmpty { XCTAssertNil(selection.next(after: preferred)) }
                else { XCTAssertTrue(available.contains(selection.next(after: preferred)!)) }
            }
            if let first = available.first {
                var current = first
                for _ in available { current = selection.next(after: current)! }
                XCTAssertEqual(current, first)
            }
        }
    }
    func testUninstallSelectedAppFallsBackAndSingleAppDoesNotSwitch() {
        let selection = ProviderSelection(installed: [.claude])
        XCTAssertEqual(selection.selected(preferred: .codex), .claude)
        XCTAssertEqual(selection.next(after: .claude), .claude)
    }
}

final class OutlineTests: XCTestCase {
    func testPriorityIsIndependentOfSelectedAppAndDetectionOrder() {
        XCTAssertEqual(ProviderSelection(installed: [.antigravity, .claude, .codex]).outlineProvider, .codex)
        XCTAssertEqual(ProviderSelection(installed: [.antigravity, .claude]).outlineProvider, .claude)
        XCTAssertEqual(ProviderSelection(installed: [.antigravity]).outlineProvider, .antigravity)
        XCTAssertNil(ProviderSelection(installed: []).outlineProvider)
    }
    func testOutlineProgressAndNormalScreenFallback() {
        let points = OutlineGeometry.points(size: CGSize(width: 190, height: 35), hasNotch: true)
        XCTAssertEqual(points.first?.y, 0)
        XCTAssertEqual(points.last?.y, 0)
        XCTAssertTrue(points.allSatisfy { $0.x >= 0 && $0.x <= 190 && $0.y >= 0 && $0.y <= 35 })
        XCTAssertTrue(OutlineGeometry.trim(points, fraction: 0).isEmpty)
        XCTAssertTrue(OutlineGeometry.trim(points, fraction: .nan).isEmpty)
        XCTAssertEqual(OutlineGeometry.trim(points, fraction: 1), points)
        let half = OutlineGeometry.trim(points, fraction: 0.5)
        XCTAssertEqual(half.last!.x, 95, accuracy: 0.01)
        XCTAssertEqual(half.last!.y, 33.5, accuracy: 0.01)
        let flat = OutlineGeometry.points(size: CGSize(width: 80, height: 4), hasNotch: false)
        XCTAssertEqual(flat.count, 2)
        XCTAssertEqual(OutlineGeometry.trim(flat, fraction: 0.5).last?.x, 40)
    }
    @MainActor func testIconsShareSmallVisualBounds() {
        for provider in Provider.allCases {
            XCTAssertEqual(max(provider.icon.size.width, provider.icon.size.height), 16, accuracy: 0.01)
        }
    }
}
