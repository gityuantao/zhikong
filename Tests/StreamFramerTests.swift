import XCTest
@testable import ZhiKong

final class StreamFramerTests: XCTestCase {
    func test_singleMessageAcrossTwoChunks() {
        let payload = Data([10, 20, 30, 40, 50])
        let framed = StreamFramer.frame(payload)
        var framer = StreamFramer()
        let a = framer.append(framed.prefix(3))       // 不足一帧
        XCTAssertTrue(a.isEmpty)
        let b = framer.append(framed.suffix(from: 3)) // 补齐
        XCTAssertEqual(b, [payload])
    }

    func test_twoMessagesInOneChunk() {
        let p1 = Data([1, 2]); let p2 = Data([3, 4, 5])
        var chunk = StreamFramer.frame(p1); chunk.append(StreamFramer.frame(p2))
        var framer = StreamFramer()
        XCTAssertEqual(framer.append(chunk), [p1, p2])
    }

    func test_emptyPayloadRoundTrips() {
        var framer = StreamFramer()
        XCTAssertEqual(framer.append(StreamFramer.frame(Data())), [Data()])
    }

    /// 帧长超上限(如恶意/损坏的 0xFFFFFFFF 前缀)→ 标记 poisoned、不囤积字节、后续输入全部丢弃。
    func test_oversizedLengthPoisonsFramer() {
        var framer = StreamFramer()
        var header = Data()
        let huge = UInt32(StreamFramer.maxFrameLength + 1).bigEndian
        withUnsafeBytes(of: huge) { header.append(contentsOf: $0) }
        XCTAssertEqual(framer.append(header), [])
        XCTAssertTrue(framer.poisoned)
        // 中毒后即使收到合法帧也不再解(流已无法对齐,调用方应断开重连)。
        XCTAssertEqual(framer.append(StreamFramer.frame(Data([1, 2, 3]))), [])
    }

    /// 中毒前已切出的完整帧仍应返回(损坏点之前的数据有效)。
    func test_framesBeforePoisonStillDelivered() {
        let good = Data([9, 9])
        var chunk = StreamFramer.frame(good)
        let huge = UInt32(StreamFramer.maxFrameLength + 1).bigEndian
        withUnsafeBytes(of: huge) { chunk.append(contentsOf: $0) }
        var framer = StreamFramer()
        XCTAssertEqual(framer.append(chunk), [good])
        XCTAssertTrue(framer.poisoned)
    }

    /// 恰好等于上限的帧长是合法的(只等待字节,不中毒)。
    func test_maxLengthHeaderIsNotPoisoned() {
        var framer = StreamFramer()
        var header = Data()
        let max = UInt32(StreamFramer.maxFrameLength).bigEndian
        withUnsafeBytes(of: max) { header.append(contentsOf: $0) }
        XCTAssertEqual(framer.append(header), [])
        XCTAssertFalse(framer.poisoned)
    }
}
