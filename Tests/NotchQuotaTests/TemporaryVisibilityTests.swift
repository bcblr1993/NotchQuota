import AppKit

import XCTest
@testable import NotchQuota

final class TemporaryVisibilityTests: XCTestCase {
    @MainActor func testDeadlineSurvivesRestartAndExpiresByWallClock() throws {
        let suite = "NotchQuota.hide.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let app = AppDelegate()
        app.hiddenUntil = now.addingTimeInterval(900)
        app.saveTemporaryVisibility(to: defaults)
        let restarted = AppDelegate()
        restarted.loadTemporaryVisibility(from: defaults, now: now.addingTimeInterval(300))
        XCTAssertEqual(restarted.hiddenUntil, now.addingTimeInterval(900))
        restarted.loadTemporaryVisibility(from: defaults, now: now.addingTimeInterval(900))
        XCTAssertFalse(restarted.temporarilyHidden)
        XCTAssertNil(defaults.object(forKey: "hiddenUntil"))
        app.hiddenUntil = nil; app.saveTemporaryVisibility(to: defaults)
        XCTAssertNil(defaults.object(forKey: "hiddenUntil"))
        defaults.set("invalid", forKey: "hiddenUntil")
        restarted.loadTemporaryVisibility(from: defaults, now: now)
        XCTAssertFalse(restarted.temporarilyHidden)
    }
    @MainActor func testDurationMenuActionsAndImmediateRestoreEntry() {
        let app = AppDelegate()
        let menu = NSMenu()
        app.appendTemporaryVisibilityMenu(to: menu)
        XCTAssertEqual(menu.items.first?.submenu?.items.map(\.tag), [900, 3600, 10800, 18000])
        XCTAssertTrue(menu.items.first?.submenu?.items.allSatisfy { $0.target === app && $0.action == #selector(AppDelegate.selectHideDuration(_:)) } == true)
        app.hiddenUntil = Date().addingTimeInterval(900)
        let hiddenMenu = NSMenu(); app.appendTemporaryVisibilityMenu(to: hiddenMenu)
        XCTAssertTrue(hiddenMenu.items.contains { $0.title == "立即显示" && $0.target === app && $0.action == #selector(AppDelegate.restoreTemporaryVisibility) })
    }
}
