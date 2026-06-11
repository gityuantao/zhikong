import XCTest
@testable import ZhiKong

final class RoomCodeTests: XCTestCase {
    func test_generate_lengthAndSafeAlphabet() {
        let allowed = Set("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        for _ in 0..<50 {
            let code = RoomCode.generate()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { allowed.contains($0) }, "应只含无歧义大写字母数字:\(code)")
            XCTAssertFalse(code.contains(where: { "01OIL".contains($0) }), "不应含易混字符:\(code)")
        }
    }

    func test_generate_varies() {
        let codes = Set((0..<20).map { _ in RoomCode.generate() })
        XCTAssertGreaterThan(codes.count, 1, "20 次生成应基本各不相同")
    }

    func test_normalize_trimsAndUppercases() {
        XCTAssertEqual(RoomCode.normalize("  abc234 \n"), "ABC234")
        XCTAssertEqual(RoomCode.normalize("Zk9F3K"), "ZK9F3K")
        XCTAssertEqual(RoomCode.normalize(""), "")
    }
}
