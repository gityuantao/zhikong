import XCTest
@testable import ZhiKong

final class InputEventTests: XCTestCase {
    func test_roundTrip_allCases() {
        let cases: [InputEvent] = [
            .mouseMove(nx: 0.25, ny: 0.75),
            .mouseButton(button: 0, down: true),
            .scroll(dx: -3.0, dy: 12.5),
            .key(keyCode: 36, down: false, modifiers: 0x1234),
        ]
        for e in cases { XCTAssertEqual(InputEvent.decode(e.encode()), e) }
    }
    func test_roundTrip_switchSpace() {
        XCTAssertEqual(InputEvent.decode(InputEvent.switchSpace(left: true).encode()),
                       .switchSpace(left: true))
        XCTAssertEqual(InputEvent.decode(InputEvent.switchSpace(left: false).encode()),
                       .switchSpace(left: false))
    }
    func test_roundTrip_missionControl() {
        XCTAssertEqual(InputEvent.decode(InputEvent.missionControl(up: true).encode()),
                       .missionControl(up: true))
        XCTAssertEqual(InputEvent.decode(InputEvent.missionControl(up: false).encode()),
                       .missionControl(up: false))
    }
    func test_decode_badTagOrTruncated_nil() {
        XCTAssertNil(InputEvent.decode(Data([0xFF])))
        XCTAssertNil(InputEvent.decode(Data([0x01, 0x00])))
    }
}
