import AppKit
import XCTest
@testable import NotchQuota

private actor AvatarResponses {
    var values: [Data?]
    private(set) var calls = 0
    init(_ values: [Data?]) { self.values = values }
    func next() -> Data? { calls += 1; return values.isEmpty ? nil : values.removeFirst() }
}

final class AvatarRetryTests: XCTestCase {
    @MainActor private func fixture() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.green, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
    @MainActor func testFailedAvatarRetriesAndThenCachesSuccess() async throws {
        let png = try fixture(), responses = AvatarResponses([nil, try fixture()])
        let loader = AccountAvatars(downloader: { _ in await responses.next() })
        let url = URL(string: "https://lh3.googleusercontent.com/fixture")!, now = Date()
        let first = await loader.data(for: url, now: now)
        let throttled = await loader.data(for: url, now: now.addingTimeInterval(59))
        XCTAssertNil(first); XCTAssertNil(throttled)
        let count = await responses.calls; XCTAssertEqual(count, 1)
        let recovered = await loader.data(for: url, now: now.addingTimeInterval(61))
        XCTAssertEqual(recovered, png)
        let cached = await loader.data(for: url, now: now.addingTimeInterval(3600))
        XCTAssertEqual(cached, png)
        let total = await responses.calls; XCTAssertEqual(total, 2)
    }
    @MainActor func testRefreshFailureRetainsAvatarAndDoesNotCrossURLs() async throws {
        let png = try fixture(), responses = AvatarResponses([try fixture(), nil, nil])
        let loader = AccountAvatars(downloader: { _ in await responses.next() })
        let url = URL(string: "https://lh3.googleusercontent.com/one")!, now = Date()
        _ = await loader.data(for: url, now: now)
        let retained = await loader.data(for: url, now: now.addingTimeInterval(86401))
        XCTAssertEqual(retained, png)
        let other = await loader.data(for: URL(string: "https://lh3.googleusercontent.com/two"), now: now)
        XCTAssertNil(other)
        let cached = await loader.data(for: url, now: now.addingTimeInterval(86410))
        XCTAssertEqual(cached, png)
        let count = await responses.calls; XCTAssertEqual(count, 3)
    }
    @MainActor func testInvalidImageRetriesAndUntrustedURLIsNotFetched() async throws {
        let png = try fixture(), responses = AvatarResponses([Data("not an image".utf8), try fixture()])
        let loader = AccountAvatars(downloader: { _ in await responses.next() })
        let denied = await loader.data(for: URL(string: "https://example.test/avatar"))
        XCTAssertNil(denied)
        let count = await responses.calls; XCTAssertEqual(count, 0)
        let url = URL(string: "https://lh3.googleusercontent.com/fixture")!, now = Date()
        let invalid = await loader.data(for: url, now: now); XCTAssertNil(invalid)
        let valid = await loader.data(for: url, now: now.addingTimeInterval(61)); XCTAssertEqual(valid, png)
    }
}
