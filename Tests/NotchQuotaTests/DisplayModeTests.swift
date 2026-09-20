import XCTest
@testable import NotchQuota

final class DisplayModeTests: XCTestCase {
    func testDetailHeightFollowsWindowsAndScreenLimit() {
        XCTAssertEqual(OverviewLayout.height(windowCount: 4, availableHeight: 900), 286)
        XCTAssertEqual(OverviewLayout.height(windowCount: 2, availableHeight: 900), 186)
        XCTAssertEqual(OverviewLayout.height(windowCount: 20, availableHeight: 700), 660)
        XCTAssertEqual(OverviewLayout.height(windowCount: 2, hasNotice: true, availableHeight: 900), 234)
    }
    func testModeDefaultsAndSavedChoice() {
        XCTAssertEqual(DisplayMode.restored(nil, majorVersion: 26), .island)
        XCTAssertEqual(DisplayMode.restored(nil, majorVersion: 27), .menuBar)
        XCTAssertEqual(DisplayMode.restored("island", majorVersion: 27), .island)
        XCTAssertEqual(DisplayMode.restored("menuBar", majorVersion: 26), .menuBar)
        XCTAssertEqual(DisplayMode.restored("invalid", majorVersion: 27), .menuBar)
    }
    func testPrimaryMissingWindowDoesNotBorrowAnotherModelLimit() {
        let rows = [QuotaWindow(id: "weekly", label: "每周", remaining: 0), .init(id: "spark", label: "Spark · 5 小时", remaining: 100)]
        let summary = QuotaSummary(rows)
        XCTAssertNil(summary.fiveHour)
        XCTAssertEqual(summary.weekly?.remaining, 0)
        XCTAssertNil(summary.group)
    }
    func testGroupedWindowsStayPairedAndPreserveResetTimes() {
        let a = Date(timeIntervalSince1970: 100), b = Date(timeIntervalSince1970: 200)
        let summary = QuotaSummary([
            .init(id: "g-w", label: "Gemini · 每周", remaining: 80, reset: a),
            .init(id: "c-f", label: "Claude / GPT · 5 小时", remaining: 1, reset: b),
            .init(id: "g-f", label: "Gemini · 5 小时", remaining: 90, reset: b)
        ])
        XCTAssertEqual(summary.group, "Gemini")
        XCTAssertEqual(summary.fiveHour?.remaining, 90)
        XCTAssertEqual(summary.weekly?.reset, a)
        XCTAssertEqual(summary.fiveHour?.reset, b)
    }
    func testUnknownWindowsAreNotInvented() {
        let summary = QuotaSummary([.init(id: "legacy", label: "Gemini Pro", remaining: 80)])
        XCTAssertNil(summary.fiveHour); XCTAssertNil(summary.weekly)
        XCTAssertEqual(QuotaSummary.resetText(nil), "未提供重置时间")
        let now = Date()
        XCTAssertEqual(QuotaSummary.resetText(now, now: now), "等待刷新")
        XCTAssertEqual(QuotaSummary.resetText(now.addingTimeInterval(3660), now: now), "1时1分后")
    }
}
