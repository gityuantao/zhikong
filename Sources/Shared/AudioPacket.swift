import Foundation

/// 网络就绪的音频帧包 —— 与 `VideoFramePacket` 复用同一条连接、同一套长度前缀分帧。
/// Client 端按 4 字节 magic 区分音/视频(`ZKV1`=视频,`ZKA1`=音频)。
///
/// 线格式(小端):
/// `magic(4B "ZKA1") | pts(8B Int64) | sampleRate(4B UInt32) | channels(1B) | codec(1B)
///  | frameCount(4B UInt32) | payload(其余全部字节)`
///
/// - `codec=0`(pcmFloat32):payload = 交织 Float32 PCM,长度 == frameCount*channels*4(局域网/兜底)。
/// - `codec=1`(aac):payload = 一个 AAC-LC 包压缩字节(变长),frameCount=1024(外网默认,省带宽)。
///
/// payload 取"头部之后的剩余全部字节"——因为整包已被 StreamFramer 长度前缀界定,无需再带 payload 长度。
struct AudioPacket: Equatable {
    enum Codec: UInt8 { case pcmFloat32 = 0, aac = 1 }

    /// 呈现时间戳,微秒。
    let pts: Int64
    /// 采样率(Hz),如 48000。
    let sampleRate: UInt32
    /// 声道数,如 2。
    let channels: UInt8
    /// 编码方式。
    let codec: Codec
    /// 本包样本帧数(PCM=实际帧数;AAC=1024)。
    let frameCount: UInt32
    /// 载荷:PCM 交织 Float32,或 AAC 压缩字节。
    let payload: Data

    static let magic: [UInt8] = [0x5A, 0x4B, 0x41, 0x31] // "ZKA1"

    // MARK: - Encode

    func encode() -> Data {
        var out = Data(capacity: 4 + 8 + 4 + 1 + 1 + 4 + payload.count)
        out.append(contentsOf: AudioPacket.magic)
        out.appendLE(UInt64(bitPattern: pts))
        out.appendLE(sampleRate)
        out.append(channels)
        out.append(codec.rawValue)
        out.appendLE(frameCount)
        out.append(payload)
        return out
    }

    // MARK: - Decode

    /// 任何越界 / magic 不符 / 未知 codec / PCM 长度对不上,一律返回 nil(绝不越界读、绝不崩溃)。
    static func decode(_ data: Data) -> AudioPacket? {
        var r = AudioByteReader(data)
        guard let m = r.readBytes(4), Array(m) == magic else { return nil }
        guard let ptsRaw = r.readUInt64LE() else { return nil }
        guard let rate = r.readUInt32LE() else { return nil }
        guard let ch = r.readUInt8() else { return nil }
        guard let codecRaw = r.readUInt8(), let codec = Codec(rawValue: codecRaw) else { return nil }
        guard let frames = r.readUInt32LE() else { return nil }
        guard let payload = r.readRemaining() else { return nil }
        // PCM 长度自洽校验;AAC 变长,但设上限拒绝异常/损坏的超大包(AAC-LC 1024样本立体声至多~1.5KB)。
        if codec == .pcmFloat32, payload.count != Int(frames) * Int(ch) * 4 { return nil }
        if codec == .aac, payload.count > 16384 { return nil }
        return AudioPacket(pts: Int64(bitPattern: ptsRaw), sampleRate: rate, channels: ch,
                           codec: codec, frameCount: frames, payload: payload)
    }
}

// MARK: - 小端写入辅助

private extension Data {
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

// MARK: - 边界安全字节读取器(与 VideoFramePacket 同形,独立私有以免互相耦合)

private struct AudioByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }
    var isAtEnd: Bool { offset == data.endIndex }
    private var remaining: Int { data.endIndex - offset }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        let start = offset; let end = offset + count; offset = end
        return Data(data[start..<end])
    }
    /// 读取剩余全部字节(可能为 0 字节,返回空 Data)。
    mutating func readRemaining() -> Data? { readBytes(remaining) }
    mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        let v = data[offset]; offset += 1; return v
    }
    mutating func readUInt32LE() -> UInt32? {
        guard let b = readBytes(4) else { return nil }
        return b.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }
    mutating func readUInt64LE() -> UInt64? {
        guard let b = readBytes(8) else { return nil }
        return b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
    }
}
