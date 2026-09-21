import XCTest
@testable import NotchQuota

final class SidebarTests: XCTestCase {
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
            XCTAssertEqual(handle.width, docked ? 18 : 40)
        } }
    }
    func testSavedSidebarModeIsRestoredOnOldAndNewSystems() {
        XCTAssertEqual(DisplayMode.restored("sidebar", majorVersion: 26), .sidebar)
        XCTAssertEqual(DisplayMode.restored("sidebar", majorVersion: 27), .sidebar)
        XCTAssertEqual(DisplayMode.allCases.count, 3)
    }
}
