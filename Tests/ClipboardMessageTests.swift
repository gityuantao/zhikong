import XCTest
@testable import ZhiKong

final class ClipboardMessageTests: XCTestCase {
    func test_roundTrip_text() {
        for s in ["hello", "你好,世界 🌍", "", "multi\nline\ttext"] {
            XCTAssertEqual(ClipboardMessage.decode(ClipboardMessage.encode(s)), s)
        }
    }

    func test_decode_wrongMagicReturnsNil() {
        XCTAssertNil(ClipboardMessage.decode(Data([0x01, 0x02, 0x03, 0x04, 0x05])))
        XCTAssertNil(ClipboardMessage.decode(Data([0x5A, 0x4B])))  // 不足 magic
        // 视频帧不应被当成剪贴板
        XCTAssertNil(ClipboardMessage.decode(VideoFramePacket(pts: 1, isKeyframe: false, parameterSets: [], nalData: Data([1])).encode()))
    }

    /// InputEvent 首字节(tag 1..6)绝不会被误判为剪贴板 magic('Z'=0x5A)。
    func test_inputEventNotMistakenForClipboard() {
        let events: [InputEvent] = [.mouseMove(nx: 0.5, ny: 0.5), .switchSpace(left: true), .missionControl(up: false)]
        for e in events {
            XCTAssertNil(ClipboardMessage.decode(e.encode()))
        }
    }
}
