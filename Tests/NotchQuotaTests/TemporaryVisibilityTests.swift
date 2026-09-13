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
        XCTAssertGreaterThanOrEqual(menu.items.first?.submenu?.minimumWidth ?? 0, 150)
        XCTAssertTrue(menu.items.first?.submenu?.items.allSatisfy { $0.target === app && $0.action == #selector(AppDelegate.selectHideDuration(_:)) } == true)
        app.hiddenUntil = Date().addingTimeInterval(900)
        let hiddenMenu = NSMenu(); app.appendTemporaryVisibilityMenu(to: hiddenMenu)
        XCTAssertTrue(hiddenMenu.items.contains { $0.title == "立即显示" && $0.target === app && $0.action == #selector(AppDelegate.restoreTemporaryVisibility) })
    }
    @MainActor func testMainMenuStaysCompactAndKeepsActionsAccessible() {
        let app = AppDelegate()
        app.detectedApps = Provider.allCases
        app.instances = [AntigravityInstance(appPath: "/Fixtures/Extra.app", credentialPath: "/Fixtures/login.json", name: "Extra")]
        var menu = app.makeMenu()
        XCTAssertLessThanOrEqual(menu.items.count, 10)
        XCTAssertEqual(menu.items.first?.title, "临时隐藏")
        let settings = menu.items.first { $0.title == "设置与更新" }?.submenu
        XCTAssertTrue(settings?.items.contains { $0.action == #selector(AppDelegate.openUpdates) } == true)
        XCTAssertTrue(settings?.items.contains { $0.title.hasPrefix("当前版本：") } == true)
        let accounts = menu.items.first { $0.title == "显示的应用" }?.submenu
        XCTAssertEqual(accounts?.items.filter { $0.action == #selector(AppDelegate.toggleProviderVisibility(_:)) }.count, 3)
        XCTAssertTrue(accounts?.items.contains { $0.action == #selector(AppDelegate.toggleInstance(_:)) } == true)
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu?.items.allSatisfy { $0.submenu == nil } ?? true }, "Menus must stay at two levels")
        app.hiddenUntil = Date().addingTimeInterval(900)
        menu = app.makeMenu()
        XCTAssertLessThanOrEqual(menu.items.count, 12)
        XCTAssertTrue(menu.items.contains { $0.action == #selector(AppDelegate.restoreTemporaryVisibility) })
    }

}
