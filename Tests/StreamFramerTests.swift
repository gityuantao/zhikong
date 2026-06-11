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
}
