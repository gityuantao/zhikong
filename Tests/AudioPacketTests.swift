import XCTest
@testable import ZhiKong

final class AudioPacketTests: XCTestCase {
    private func pcm(_ floats: [Float]) -> Data {
        var d = Data(capacity: floats.count * 4)
        for f in floats { var v = f; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        return d
    }

    func test_roundTrip_pcmStereo() {
        let p = AudioPacket(pts: 987654, sampleRate: 48000, channels: 2, codec: .pcmFloat32,
                            frameCount: 3, payload: pcm([0.1, -0.2, 0.3, -0.4, 0.5, -0.6]))
        XCTAssertEqual(AudioPacket.decode(p.encode()), p)
    }

    func test_roundTrip_pcmMonoEmpty() {
        let p = AudioPacket(pts: 0, sampleRate: 44100, channels: 1, codec: .pcmFloat32,
                            frameCount: 0, payload: Data())
        XCTAssertEqual(AudioPacket.decode(p.encode()), p)
    }

    func test_roundTrip_aacVariableLength() {
        // AAC 包载荷变长(不等于 frameCount*ch*4),decode 不应做 PCM 长度校验。
        let p = AudioPacket(pts: 123, sampleRate: 48000, channels: 2, codec: .aac,
                            frameCount: 1024, payload: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01]))
        XCTAssertEqual(AudioPacket.decode(p.encode()), p)
    }

    func test_decode_aacOversizedRejected() {
        // AAC 包超 16KB 上限 → 拒绝(防异常/损坏的超大包打到系统解码器)。
        let big = AudioPacket(pts: 0, sampleRate: 48000, channels: 2, codec: .aac,
                              frameCount: 1024, payload: Data(repeating: 0xAB, count: 20000))
        XCTAssertNil(AudioPacket.decode(big.encode()))
        // 合理大小的 AAC 包仍可解。
        let ok = AudioPacket(pts: 0, sampleRate: 48000, channels: 2, codec: .aac,
                             frameCount: 1024, payload: Data(repeating: 0xAB, count: 800))
        XCTAssertEqual(AudioPacket.decode(ok.encode()), ok)
    }

    func test_decode_truncatedReturnsNil() {
        XCTAssertNil(AudioPacket.decode(Data([0x5A, 0x4B, 0x41]))) // 不足 magic
    }

    func test_decode_wrongMagicReturnsNil() {
        XCTAssertNil(AudioPacket.decode(VideoFramePacket(pts: 1, isKeyframe: false, parameterSets: [], nalData: Data([1])).encode()))
    }

    func test_decode_unknownCodecReturnsNil() {
        var bad = Data()
        bad.append(contentsOf: AudioPacket.magic)
        bad.append(contentsOf: [UInt8](repeating: 0, count: 8))    // pts
        bad.append(contentsOf: [0x80, 0xBB, 0x00, 0x00])           // 48000 LE
        bad.append(2)                                              // channels
        bad.append(0xFE)                                           // 未知 codec
        bad.append(contentsOf: [0, 4, 0, 0])                       // frameCount
        bad.append(contentsOf: [1, 2, 3])
        XCTAssertNil(AudioPacket.decode(bad))
    }

    func test_decode_pcmLengthMismatchReturnsNil() {
        var bad = Data()
        bad.append(contentsOf: AudioPacket.magic)
        bad.append(contentsOf: [UInt8](repeating: 0, count: 8))    // pts
        bad.append(contentsOf: [0x80, 0xBB, 0x00, 0x00])           // 48000 LE
        bad.append(2)                                              // channels
        bad.append(0)                                             // codec=pcmFloat32
        bad.append(contentsOf: [4, 0, 0, 0])                       // frameCount=4 → 需 4*2*4=32 字节
        bad.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])           // 只 8 字节
        XCTAssertNil(AudioPacket.decode(bad))
    }
}
