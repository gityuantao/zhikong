import XCTest
@testable import ZhiKong

final class VideoFramePacketTests: XCTestCase {
    func test_roundTrip_keyframeWithParameterSets() {
        let p = VideoFramePacket(pts: 123456, isKeyframe: true,
                                 parameterSets: [Data([1, 2, 3]), Data([4, 5])],
                                 nalData: Data([9, 9, 9, 9]))
        let decoded = VideoFramePacket.decode(p.encode())
        XCTAssertEqual(decoded, p)
    }

    func test_roundTrip_nonKeyframeNoParams() {
        let p = VideoFramePacket(pts: 7, isKeyframe: false, parameterSets: [], nalData: Data([1, 2]))
        XCTAssertEqual(VideoFramePacket.decode(p.encode()), p)
    }

    func test_decode_truncatedReturnsNil() {
        XCTAssertNil(VideoFramePacket.decode(Data([0x5A, 0x4B])))
    }
}
