import XCTest
@testable import NotchQuota

final class AccountOrderTests: XCTestCase {
    func testOrderSupportsEightInstancesAndIgnoresUnknownDuplicateIDs() {
        let targets = (1...8).map { QuotaTarget(provider: .antigravity, instance: .init(appPath: "/fixtures/\($0).app", credentialPath: "/fixtures/\($0).json", name: "Account \($0)")) }
        let saved = Array(targets.reversed()).map(\.id)
        XCTAssertEqual(AccountOrder.apply(targets, saved: ["missing"] + saved + saved), Array(targets.reversed()))
        XCTAssertEqual(AccountOrder.apply(targets, saved: []), targets)
        XCTAssertEqual(AccountOrder.apply(targets + [.codex], saved: saved).last, .codex)
    }
    func testReorderingVisibleAccountsPreservesHiddenSlots() {
        XCTAssertEqual(AccountOrder.merging(["c", "a", "new"], into: ["a", "hidden", "c", "c"]), ["c", "hidden", "a", "new"])
    }
    @MainActor func testOrderPersistsWithoutEnablingOrChangingAccounts() throws {
        let suite = "NotchQuota.order.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate(); app.accountOrder = ["claude", "codex"]
        app.enabledInstances = ["fixture"]; app.saveAccountPreferences(to: defaults)
        let restarted = AppDelegate(); restarted.loadAccountPreferences(from: defaults)
        XCTAssertEqual(restarted.accountOrder, app.accountOrder)
        XCTAssertEqual(restarted.enabledInstances, ["fixture"])
    }
}
