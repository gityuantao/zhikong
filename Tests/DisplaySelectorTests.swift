import XCTest
import CoreGraphics
@testable import ZhiKong

private struct MockDisplay: DisplayIdentifiable {
    let displayID: CGDirectDisplayID
}

final class DisplaySelectorTests: XCTestCase {
    func test_picksDisplayMatchingMainID() {
        let displays = [MockDisplay(displayID: 1), MockDisplay(displayID: 7), MockDisplay(displayID: 3)]
        XCTAssertEqual(DisplaySelector.main(from: displays, preferring: 7)?.displayID, 7)
    }
    func test_fallsBackToFirstWhenNoMatch() {
        let displays = [MockDisplay(displayID: 4), MockDisplay(displayID: 5)]
        XCTAssertEqual(DisplaySelector.main(from: displays, preferring: 99)?.displayID, 4)
    }
    func test_returnsNilWhenEmpty() {
        let displays: [MockDisplay] = []
        XCTAssertNil(DisplaySelector.main(from: displays, preferring: 1))
    }
}
