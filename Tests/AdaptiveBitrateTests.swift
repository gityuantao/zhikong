import XCTest
@testable import ZhiKong

final class AdaptiveBitrateTests: XCTestCase {
    func test_congestion_dropsBitrate() {
        var c = AdaptiveBitrateController(start: 8_000_000, floor: 2_000_000, ceiling: 8_000_000)
        let after = c.update(deliveryRatio: 0.5)   // 收到一半的帧 → 拥塞
        XCTAssertEqual(after, 6_000_000)            // 8M*0.75
        XCTAssertLessThan(c.update(deliveryRatio: 0.4), 6_000_000)
    }

    func test_floor_clamped() {
        var c = AdaptiveBitrateController(start: 3_000_000, floor: 2_000_000, ceiling: 8_000_000)
        for _ in 0..<20 { c.update(deliveryRatio: 0.0) }
        XCTAssertEqual(c.bitrate, 2_000_000, "不应跌破下限")
    }

    func test_protective_default_noUpwardProbing() {
        // ceiling == start → 保护式:通畅也不超过起始码率。
        var c = AdaptiveBitrateController(start: 7_000_000, floor: 2_000_000, ceiling: 7_000_000)
        for _ in 0..<20 { c.update(deliveryRatio: 1.0) }
        XCTAssertEqual(c.bitrate, 7_000_000)
    }

    func test_healthy_raisesWhenCeilingHigher_afterStreak() {
        var c = AdaptiveBitrateController(start: 7_000_000, floor: 2_000_000, ceiling: 12_000_000)
        // 需连续 raiseStreak(3) 次通畅才升一档
        XCTAssertEqual(c.update(deliveryRatio: 1.0), 7_000_000)
        XCTAssertEqual(c.update(deliveryRatio: 1.0), 7_000_000)
        XCTAssertEqual(c.update(deliveryRatio: 1.0), 8_000_000)  // 第3次 → +1M
    }

    func test_recoversToCeiling_thenStops() {
        var c = AdaptiveBitrateController(start: 5_000_000, floor: 2_000_000, ceiling: 6_000_000)
        for _ in 0..<30 { c.update(deliveryRatio: 1.0) }
        XCTAssertEqual(c.bitrate, 6_000_000, "升到 ceiling 即止")
    }

    func test_middleBand_holds() {
        var c = AdaptiveBitrateController(start: 7_000_000, floor: 2_000_000, ceiling: 12_000_000)
        for _ in 0..<10 { c.update(deliveryRatio: 0.90) }   // 0.85..0.95 中间带
        XCTAssertEqual(c.bitrate, 7_000_000)
    }

    func test_feedbackMessage_roundTrip() {
        for fps in [0.0, 30.0, 59.6, 60.0, 120.0] {
            let decoded = FeedbackMessage.decode(FeedbackMessage.encode(fps: fps))
            XCTAssertEqual(decoded, fps.rounded())
        }
        XCTAssertNil(FeedbackMessage.decode(Data([0x01, 0x02])))
        XCTAssertNil(FeedbackMessage.decode(ClipboardMessage.encode("x")))
    }
}
