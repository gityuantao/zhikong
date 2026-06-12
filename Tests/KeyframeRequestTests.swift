import XCTest
@testable import ZhiKong

final class KeyframeRequestTests: XCTestCase {
    func test_encodeIsExactlyMagic() {
        XCTAssertEqual(KeyframeRequest.encode(), Data([0x5A, 0x4B, 0x4B, 0x52]))
    }

    func test_roundTrip() {
        XCTAssertTrue(KeyframeRequest.isRequest(KeyframeRequest.encode()))
    }

    func test_rejectsWrongMagicAndLength() {
        XCTAssertFalse(KeyframeRequest.isRequest(Data([0x5A, 0x4B, 0x4B, 0x00])))   // magic 不符
        XCTAssertFalse(KeyframeRequest.isRequest(Data([0x5A, 0x4B, 0x4B])))         // 太短
        XCTAssertFalse(KeyframeRequest.isRequest(KeyframeRequest.encode() + [0]))   // 带尾巴
        XCTAssertFalse(KeyframeRequest.isRequest(Data()))                           // 空
    }

    /// 带非零 startIndex 的切片也能正确判定(Data 切片索引基防御)。
    func test_sliceWithNonZeroStartIndex() {
        let padded = Data([0xFF]) + KeyframeRequest.encode()
        XCTAssertTrue(KeyframeRequest.isRequest(padded.dropFirst()))
    }
}
