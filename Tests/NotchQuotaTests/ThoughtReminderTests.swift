import XCTest
@testable import NotchQuota

final class ThoughtReminderTests: XCTestCase {
    func testRecoveryRequiresKnownTransitionToOneHundredForEachWindow() {
        func snapshot(_ five: Double?, _ week: Double?) -> Snapshot {
            Snapshot(windows: [
                .init(id: "five_hour", label: "5 小时", remaining: five, reset: nil),
                .init(id: "seven_day", label: "每周", remaining: week, reset: nil)
            ])
        }
        let before = snapshot(82, 0)
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: nil, current: snapshot(100, 100)), [])
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: before, current: snapshot(100, 0)), ["5 小时"])
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: before, current: snapshot(82, 100)), ["每周"])
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: before, current: snapshot(100, 100)), ["5 小时", "每周"])
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: snapshot(100, 100), current: snapshot(100, 100)), [])
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: snapshot(nil, 50), current: snapshot(100, 99)), [])
    }
    func testRecoveryDoesNotConfuseDifferentWindowsOrUnrelatedQuota() {
        let before = Snapshot(windows: [
            .init(id: "old", label: "5 小时", remaining: 2, reset: nil),
            .init(id: "model", label: "Gemini · 每周", remaining: 35, reset: nil),
            .init(id: "other", label: "月度", remaining: 10, reset: nil)
        ])
        let after = Snapshot(windows: [
            .init(id: "new", label: "5 小时", remaining: 100, reset: nil),
            .init(id: "model", label: "Gemini · 每周", remaining: 100, reset: nil),
            .init(id: "other", label: "月度", remaining: 100, reset: nil)
        ])
        XCTAssertEqual(QuotaRecoveryDetector.restoredWindows(previous: before, current: after), ["Gemini · 每周"])
        XCTAssertEqual(RecoveryAnnouncement(windows: ["5 小时", "每周"], style: .cloud).title, "5 小时与每周额度")
    }
    func testRotationSurvivesAccountRemovalAndReordering() {
        var cycle = ReminderCycle()
        XCTAssertEqual(cycle.next(in: ["a", "b", "c"]), "a")
        XCTAssertEqual(cycle.next(in: ["a", "b", "c"]), "b")
        XCTAssertEqual(cycle.next(in: ["c", "b", "a"]), "a")
        XCTAssertEqual(cycle.next(in: ["b", "c"]), "b")
        XCTAssertNil(cycle.next(in: []))
        XCTAssertEqual(cycle.next(in: ["c"]), "c")
        XCTAssertEqual(cycle.next(in: ["c"]), "c")
    }
    func testOnlySuccessfulNewFetchCanRemindIncludingRealZero() {
        let now = Date()
        let snapshot = Snapshot(windows: [.init(id: "week", label: "每周", remaining: 0, reset: nil)], fetchedAt: now)
        XCTAssertTrue(ReminderFreshness.accepts(DisplayState(snapshot: snapshot), since: now.addingTimeInterval(-1)))
        XCTAssertFalse(ReminderFreshness.accepts(DisplayState(snapshot: snapshot), since: now.addingTimeInterval(1)))
        XCTAssertFalse(ReminderFreshness.accepts(DisplayState(snapshot: snapshot, error: "offline"), since: now))
        XCTAssertFalse(ReminderFreshness.accepts(DisplayState(snapshot: snapshot, loading: true), since: now))
        XCTAssertFalse(ReminderFreshness.accepts(DisplayState(snapshot: Snapshot(windows: [], fetchedAt: now)), since: now))
        let old = Snapshot(windows: snapshot.windows, fetchedAt: now.addingTimeInterval(-700))
        XCTAssertFalse(ReminderFreshness.accepts(DisplayState(snapshot: old), since: now.addingTimeInterval(-800)))
    }
    func testCloudFitsAllEdgesOnOffsetDisplay() {
        let screen = CGRect(x: -1920, y: -400, width: 1920, height: 1080)
        for x in [screen.minX, screen.midX, screen.maxX - 50] {
            for y in [screen.minY, screen.midY, screen.maxY - 90] {
                let anchor = CGRect(x: x, y: y, width: 50, height: 90)
                let cloud = ThoughtLayout.frame(anchor: anchor, screen: screen)
                XCTAssertTrue(screen.contains(cloud))
                XCTAssertFalse(anchor.intersects(cloud))
            }
        }
    }
}
