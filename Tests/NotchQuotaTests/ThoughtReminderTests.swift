import XCTest
@testable import NotchQuota

final class ThoughtReminderTests: XCTestCase {
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
