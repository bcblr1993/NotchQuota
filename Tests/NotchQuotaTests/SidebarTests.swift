import XCTest
@testable import NotchQuota

final class SidebarTests: XCTestCase {
    func testAppearanceRestoresAndUnknownPreferenceFallsBack() {
        XCTAssertEqual(SidebarAppearance.restored(nil), .capsule)
        XCTAssertEqual(SidebarAppearance.restored("unknown-future-style"), .capsule)
        for style in SidebarAppearance.allCases {
            XCTAssertEqual(SidebarAppearance.restored(style.rawValue), style)
        }
    }
    func testPinnedDisplayIgnoresPointerFocusAndScreenOrdering() {
        for initial: UInt32 in [1, 2, 3] {
            XCTAssertEqual(SidebarLayout.displayID(saved: 2, available: [1, 2, 3], initial: initial), 2)
            XCTAssertEqual(SidebarLayout.displayID(saved: 2, available: [3, 2, 1], initial: initial), 2)
        }
    }
    func testFirstPlacementAndDisconnectedDisplayHaveStableFallback() {
        let first = SidebarLayout.displayID(saved: nil, available: [1, 2], initial: 2)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(SidebarLayout.displayID(saved: first, available: [1, 2], initial: 1), 2)
        let fallback = SidebarLayout.displayID(saved: 2, available: [1, 3], initial: 3)
        XCTAssertEqual(fallback, 1)
        XCTAssertEqual(SidebarLayout.displayID(saved: fallback, available: [1, 2, 3], initial: 2), 1)
        XCTAssertNil(SidebarLayout.displayID(saved: 2, available: [], initial: 1))
    }
    func testBothEdgesAndClampedPositionOnExternalDisplay() {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1000)
        for right in [false, true] {
            for fraction in [-1.0, 0, 0.5, 1, 2] {
                let frame = SidebarLayout.frame(count: 7, screen: screen, right: right, fraction: fraction)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(frame.width, 52)
                XCTAssertEqual(frame.height, 398)
                XCTAssertEqual(right ? screen.maxX - frame.maxX : frame.minX - screen.minX, 0)
            }
        }
    }
    func testManyAccountsFitSmallScreenAndSingleAccountShrinks() {
        let screen = CGRect(x: 0, y: 30, width: 800, height: 500)
        XCTAssertEqual(SidebarLayout.frame(count: 1, screen: screen, right: true, fraction: 0.5).height, 74)
        XCTAssertTrue(screen.contains(SidebarLayout.frame(count: 100, screen: screen, right: true, fraction: 0.5)))
    }
    func testDetailsStayInsideScreenAtTopAndBottomOnBothSides() {
        let screen = CGRect(x: -1440, y: -900, width: 1440, height: 860)
        for right in [false, true] {
            let bar = SidebarLayout.frame(count: 7, screen: screen, right: right, fraction: 0.5)
            for y in [screen.minY, screen.maxY] {
                let detail = SidebarLayout.detailFrame(bar: bar, rowY: y, size: CGSize(width: 320, height: 286), screen: screen, right: right)
                XCTAssertTrue(screen.contains(detail))
                XCTAssertFalse(detail.intersects(bar))
            }
        }
    }
    func testFreeFloatingAndEdgeHandlesRemainWithinDisplay() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 900)
        let expanded = SidebarLayout.floatingFrame(count: 7, screen: screen, xFraction: 0.5, yFraction: 0.5)
        XCTAssertEqual(expanded.midX, screen.midX)
        for docked in [true, false] { for right in [true, false] {
            let handle = SidebarLayout.collapsedFrame(expanded: expanded, screen: screen, docked: docked, right: right)
            XCTAssertTrue(screen.contains(handle))
            XCTAssertEqual(handle.width, 40)
            let peek = SidebarLayout.collapsedFrame(expanded: expanded, screen: screen, docked: docked, right: right, peeking: true)
            XCTAssertTrue(screen.contains(peek))
            XCTAssertEqual(peek.width, 40)
            if docked { XCTAssertEqual(right ? peek.maxX : peek.minX, right ? handle.maxX : handle.minX) }
        } }
    }
    func testEnlargedFloatingStylesStayOnScreenNearEdges() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 900)
        for style in SidebarAppearance.allCases {
            for x in [0.0, 1.0] {
                let expanded = SidebarLayout.floatingFrame(count: 1, screen: screen, xFraction: x, yFraction: 1)
                let frame = SidebarLayout.collapsedFrame(expanded: expanded, screen: screen, docked: false, right: true, scale: style.scale)
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }
    func testSavedSidebarModeIsRestoredOnOldAndNewSystems() {
        XCTAssertEqual(DisplayMode.restored("sidebar", majorVersion: 26), .sidebar)
        XCTAssertEqual(DisplayMode.restored("sidebar", majorVersion: 27), .sidebar)
        XCTAssertEqual(DisplayMode.allCases.count, 3)
    }
}
