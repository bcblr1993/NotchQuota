import XCTest
@testable import NotchQuotaKit

final class AlertDetectorTests: XCTestCase {
    private let detector = AlertDetector()

    private func account(_ remaining: Double?, reset: Date? = nil) -> Account {
        Account(id: "codex-work", provider: .codex, label: "工作 ChatGPT",
                snapshot: Snapshot(windows: [.init(id: "w", label: "5 小时", remaining: remaining, reset: reset)]))
    }

    /// Walks the sequence from the design note end to end.
    func testFullLifecycleFiresEachEdgeExactlyOnce() {
        var level: AlertLevel?
        var fired: [QuotaAlert] = []
        for remaining in [42, 12, 8, 5, nil, 0, 18, 100] as [Double?] {
            let (next, alert) = detector.evaluate(account(remaining), previous: level)
            level = next
            if let alert { fired.append(alert) }
        }
        XCTAssertEqual(fired.count, 2, "整段只应产生跌破和恢复各一次")
        guard fired.count == 2 else { return }
        if case .low(_, _, _, let remaining, _) = fired[0] { XCTAssertEqual(remaining, 8) } else { XCTFail("第一条应为额度不足") }
        if case .recovered(_, _, _, let remaining) = fired[1] { XCTAssertEqual(remaining, 100) } else { XCTFail("第二条应为额度恢复") }
    }

    func testFirstObservationOnlyRecordsLevel() {
        let (level, alert) = detector.evaluate(account(3), previous: nil)
        XCTAssertEqual(level, .low)
        XCTAssertNil(alert, "首次观测不推送，否则每次启动都会刷屏")
    }

    func testUnknownReadingHoldsLevelAndStaysSilent() {
        let (level, alert) = detector.evaluate(account(nil), previous: .low)
        XCTAssertEqual(level, .low, "未知不得触发恢复")
        XCTAssertNil(alert)

        let (normalLevel, normalAlert) = detector.evaluate(account(nil), previous: .normal)
        XCTAssertEqual(normalLevel, .normal)
        XCTAssertNil(normalAlert)
    }

    func testGenuineZeroDiffersFromUnknown() {
        let (level, alert) = detector.evaluate(account(0), previous: .normal)
        XCTAssertEqual(level, .low)
        XCTAssertNotNil(alert, "真实耗尽必须告警，而未知不能")
    }

    func testHysteresisBandHoldsInBothDirections() {
        for value in [10.0, 18.0, 24.9] {
            XCTAssertEqual(detector.evaluate(account(value), previous: .low).level, .low, "\(value)% 尚未恢复")
            XCTAssertEqual(detector.evaluate(account(value), previous: .normal).level, .normal, "\(value)% 不应触发告警")
        }
    }

    func testThresholdBoundaries() {
        XCTAssertEqual(detector.evaluate(account(9.99), previous: .normal).level, .low)
        XCTAssertEqual(detector.evaluate(account(10), previous: .normal).level, .normal, "10% 不算跌破")
        XCTAssertEqual(detector.evaluate(account(25), previous: .low).level, .normal, "25% 算恢复")
        XCTAssertEqual(detector.evaluate(account(24.99), previous: .low).level, .low)
    }

    func testSustainedLowDoesNotRepeat() {
        var level: AlertLevel? = .normal
        var count = 0
        for _ in 0..<20 {
            let (next, alert) = detector.evaluate(account(4), previous: level)
            level = next
            if alert != nil { count += 1 }
        }
        XCTAssertEqual(count, 1, "持续低位只推一次")
    }

    func testLowAlertCarriesBindingResetTime() {
        let reset = Date().addingTimeInterval(7200)
        let (_, alert) = detector.evaluate(account(4, reset: reset), previous: .normal)
        guard case .low(_, _, _, _, let carried)? = alert else { return XCTFail("应为额度不足") }
        XCTAssertEqual(carried, reset)
    }

    func testAlertTextUsesAccountLabel() {
        let (_, alert) = detector.evaluate(account(4), previous: .normal)
        XCTAssertEqual(alert?.title, "工作 ChatGPT 额度不足", "多账号下必须能分辨是哪个账号")
        XCTAssertEqual(alert?.accountID, "codex-work")
    }

    func testCountdownWording() {
        let now = Date()
        XCTAssertEqual(QuotaAlert.countdown(to: now.addingTimeInterval(172_800), from: now), "2 天")
        XCTAssertEqual(QuotaAlert.countdown(to: now.addingTimeInterval(7_800), from: now), "2 小时 10 分")
        XCTAssertEqual(QuotaAlert.countdown(to: now.addingTimeInterval(300), from: now), "5 分钟")
        XCTAssertEqual(QuotaAlert.countdown(to: now.addingTimeInterval(-60), from: now), "0 分钟", "已过期不显示负数")
    }

    func testAccountsAreTrackedIndependently() {
        let codex = Account(id: "a", provider: .codex, label: "A", snapshot: Snapshot(windows: [.init(id: "w", label: "w", remaining: 4)]))
        let claude = Account(id: "b", provider: .claude, label: "B", snapshot: Snapshot(windows: [.init(id: "w", label: "w", remaining: 90)]))
        XCTAssertNotNil(detector.evaluate(codex, previous: .normal).alert)
        XCTAssertNil(detector.evaluate(claude, previous: .normal).alert)
    }
}

final class AccountTests: XCTestCase {
    func testStalenessFollowsTheMacRule() {
        let now = Date()
        let fresh = Account(id: "a", provider: .codex, label: "A", snapshot: Snapshot(windows: [], fetchedAt: now))
        XCTAssertFalse(fresh.isStale(now: now))

        let old = Account(id: "a", provider: .codex, label: "A", snapshot: Snapshot(windows: [], fetchedAt: now.addingTimeInterval(-601)))
        XCTAssertTrue(old.isStale(now: now))

        var failed = fresh
        failed.error = "网络未连接"
        XCTAssertTrue(failed.isStale(now: now), "读取失败时旧数据要标记过期")

        let empty = Account(id: "a", provider: .codex, label: "A")
        XCTAssertFalse(empty.isStale(now: now), "从未取过数不算过期")
    }

    func testLevelDerivesFromLowestWindow() {
        let account = Account(id: "a", provider: .codex, label: "A", snapshot: Snapshot(windows: [
            .init(id: "1", label: "每周", remaining: 80),
            .init(id: "2", label: "5 小时", remaining: 15)
        ]))
        XCTAssertEqual(account.remaining, 15)
        XCTAssertEqual(account.level, .critical)
    }

    func testOrderIsStableAcrossRefreshes() {
        let accounts = [
            Account(id: "z", provider: .antigravity, label: "Antigravity"),
            Account(id: "b", provider: .codex, label: "个人"),
            Account(id: "a", provider: .codex, label: "工作"),
            Account(id: "c", provider: .claude, label: "Claude")
        ]
        let sorted = AccountOrder.sorted(accounts)
        XCTAssertEqual(sorted.map(\.id), ["b", "a", "c", "z"], "先按应用优先级，再按标签，布局不得跳动")
        XCTAssertEqual(AccountOrder.sorted(sorted).map(\.id), sorted.map(\.id), "排序是幂等的")
    }
}
