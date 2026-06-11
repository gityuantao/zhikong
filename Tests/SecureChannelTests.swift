import XCTest
@testable import ZhiKong

final class SecureChannelTests: XCTestCase {
    private let secret = "correct horse battery staple"

    private func hostClient() -> (host: SecureChannel, client: SecureChannel) {
        (SecureChannel(secret: secret, sending: .hostToClient),
         SecureChannel(secret: secret, sending: .clientToHost))
    }

    // MARK: - 往返(两个方向)

    func test_roundTrip_hostToClient() {
        let (host, client) = hostClient()
        let plain = Data("被控机 → 控制端 的一帧视频载荷".utf8)
        let sealed = host.seal(plain)
        XCTAssertNotNil(sealed)
        XCTAssertEqual(client.open(sealed!), plain)
    }

    func test_roundTrip_clientToHost() {
        let (host, client) = hostClient()
        let plain = Data([1, 2, 3, 4, 5, 6, 7, 8])  // 模拟一条输入事件
        let sealed = client.seal(plain)
        XCTAssertNotNil(sealed)
        XCTAssertEqual(host.open(sealed!), plain)
    }

    func test_roundTrip_emptyPayload() {
        let (host, client) = hostClient()
        let sealed = host.seal(Data())
        XCTAssertNotNil(sealed)
        XCTAssertEqual(client.open(sealed!), Data())
    }

    // MARK: - 安全性质

    /// 口令不一致 → 解不开(模拟两端配错口令)。
    func test_wrongSecret_failsToOpen() {
        let host = SecureChannel(secret: secret, sending: .hostToClient)
        let client = SecureChannel(secret: "另一个口令", sending: .clientToHost)
        let sealed = host.seal(Data("机密".utf8))!
        XCTAssertNil(client.open(sealed))
    }

    /// 篡改密文任一字节 → 完整性校验失败,解不开(AEAD tag 生效)。
    func test_tamperedCiphertext_failsToOpen() {
        let (host, client) = hostClient()
        var sealed = host.seal(Data("机密内容".utf8))!
        let mid = sealed.index(sealed.startIndex, offsetBy: sealed.count / 2)
        sealed[mid] ^= 0xFF
        XCTAssertNil(client.open(sealed))
    }

    /// 方向反射:Host 封的帧用 Host 自己开(方向相同 → AAD 不符)→ 失败。防中转回灌。
    func test_reflection_sameDirection_failsToOpen() {
        let host = SecureChannel(secret: secret, sending: .hostToClient)
        let sealed = host.seal(Data("视频帧".utf8))!
        XCTAssertNil(host.open(sealed))  // openAAD=C2H,但帧用 sealAAD=H2C 封 → 不符
    }

    /// 截断/过短密文不崩,返回 nil。
    func test_truncatedCiphertext_returnsNilNoCrash() {
        let (_, client) = hostClient()
        XCTAssertNil(client.open(Data()))
        XCTAssertNil(client.open(Data([0x00])))
        XCTAssertNil(client.open(Data(repeating: 0xAB, count: 10)))  // 不足 nonce+tag 开销
    }

    /// 每帧随机 nonce:同明文两次封出的密文不同(否则等于固定 nonce,有复用风险)。
    func test_randomNonce_differentCiphertextsForSamePlaintext() {
        let host = SecureChannel(secret: secret, sending: .hostToClient)
        let plain = Data("同一帧".utf8)
        let a = host.seal(plain)!
        let b = host.seal(plain)!
        XCTAssertNotEqual(a, b, "随机 nonce 应使两次密文不同")
        // 但都能被正确开箱
        let client = SecureChannel(secret: secret, sending: .clientToHost)
        XCTAssertEqual(client.open(a), plain)
        XCTAssertEqual(client.open(b), plain)
    }

    /// 开销合理(nonce 12 + tag 16 = 28 字节固定开销)。
    func test_overhead_is28Bytes() {
        let host = SecureChannel(secret: secret, sending: .hostToClient)
        let plain = Data(repeating: 0x42, count: 1000)
        let sealed = host.seal(plain)!
        XCTAssertEqual(sealed.count, plain.count + 28)
    }

    // MARK: - 线格式往返(两端实际走的完整变换:encode→seal→frame→deframe→open→decode)

    /// 视频帧:Host 侧 seal+frame → 解帧 → Client open → decode,应还原原帧。
    func test_wireRoundTrip_videoPacket() {
        let (host, client) = hostClient()
        let packet = VideoFramePacket(pts: 123_456, isKeyframe: true,
                                      parameterSets: [Data([0xAA, 0xBB]), Data([0xCC])],
                                      nalData: Data(repeating: 0x9E, count: 512))
        // Host 发送侧
        let body = host.seal(packet.encode())!
        let onWire = StreamFramer.frame(body)
        // Client 接收侧
        var framer = StreamFramer()
        let frames = framer.append(onWire)
        XCTAssertEqual(frames.count, 1)
        let plain = client.open(frames[0])
        XCTAssertNotNil(plain)
        let decoded = VideoFramePacket.decode(plain!)
        XCTAssertEqual(decoded, packet)
    }

    /// 输入事件:Client 侧 seal+frame → 解帧 → Host open → decode,应还原原事件。
    func test_wireRoundTrip_inputEvent() {
        let (host, client) = hostClient()
        let event = InputEvent.mouseMove(nx: 0.321, ny: 0.654)
        let body = client.seal(event.encode())!
        let onWire = StreamFramer.frame(body)
        var framer = StreamFramer()
        let frames = framer.append(onWire)
        XCTAssertEqual(frames.count, 1)
        let plain = host.open(frames[0])
        XCTAssertNotNil(plain)
        XCTAssertEqual(InputEvent.decode(plain!), event)
    }

    /// 多帧在一个 TCP 块里粘连:解帧 + 逐帧开箱都应正确分离还原。
    func test_wireRoundTrip_multipleFramesCoalesced() {
        let (host, client) = hostClient()
        let p1 = VideoFramePacket(pts: 1, isKeyframe: false, parameterSets: [], nalData: Data([0x01, 0x02]))
        let p2 = VideoFramePacket(pts: 2, isKeyframe: false, parameterSets: [], nalData: Data([0x03, 0x04, 0x05]))
        var wire = Data()
        wire.append(StreamFramer.frame(host.seal(p1.encode())!))
        wire.append(StreamFramer.frame(host.seal(p2.encode())!))
        var framer = StreamFramer()
        let frames = framer.append(wire)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(VideoFramePacket.decode(client.open(frames[0])!), p1)
        XCTAssertEqual(VideoFramePacket.decode(client.open(frames[1])!), p2)
    }

    /// 房间码兜底口令:secret 缺省时 effectiveSecret == room,两端仍一致可通。
    func test_fallbackSecret_roomDerivedKeyStillInterops() {
        let cfg = RelayConfig(host: "1.2.3.4", port: 7777, room: "room123", secret: nil)
        XCTAssertTrue(cfg.usesFallbackSecret)
        XCTAssertEqual(cfg.effectiveSecret, "room123")
        let host = SecureChannel(secret: cfg.effectiveSecret, sending: .hostToClient)
        let client = SecureChannel(secret: cfg.effectiveSecret, sending: .clientToHost)
        let plain = Data("兜底也能通".utf8)
        XCTAssertEqual(client.open(host.seal(plain)!), plain)
    }
}
