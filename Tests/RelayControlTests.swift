import XCTest
@testable import ZhiKong

final class RelayControlTests: XCTestCase {
    func test_presence_roundTrip() {
        XCTAssertEqual(RelayControl.decodePresence(RelayControl.encodePresence(true)), true)
        XCTAssertEqual(RelayControl.decodePresence(RelayControl.encodePresence(false)), false)
        XCTAssertEqual(RelayControl.encodePresence(true).count, 5)
    }

    func test_decode_rejectsWrongLengthOrMagic() {
        XCTAssertNil(RelayControl.decodePresence(Data([0x5A, 0x4B, 0x52, 0x4C])))            // 4 字节(缺 flag)
        XCTAssertNil(RelayControl.decodePresence(Data([0x5A, 0x4B, 0x52, 0x4C, 1, 2])))      // 6 字节
        XCTAssertNil(RelayControl.decodePresence(Data([0x01, 0x02, 0x03, 0x04, 0x01])))      // 5 字节但非 ZKRL
    }

    /// 与其它消息不撞:加密帧≥28字节;1字符剪贴板 ZKC1 虽 5 字节但 magic≠ZKRL。
    func test_notConfusedWithClipboardOrEncrypted() {
        let oneCharClip = ClipboardMessage.encode("x")   // ZKC1 + 1 字节 = 5 字节
        XCTAssertEqual(oneCharClip.count, 5)
        XCTAssertNil(RelayControl.decodePresence(oneCharClip))   // magic 是 ZKC1 不是 ZKRL → 不误判
        // 加密帧远大于 5 字节
        let sealed = SecureChannel(secret: "k", sending: .hostToClient).seal(Data([1]))!
        XCTAssertGreaterThan(sealed.count, 5)
        XCTAssertNil(RelayControl.decodePresence(sealed))
    }
}
