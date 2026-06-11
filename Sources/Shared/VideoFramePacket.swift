import Foundation

/// 网络就绪的视频帧包 —— 也是 M3 过网的线格式。
///
/// 线格式(小端):
/// `magic(4B "ZKV1") | pts(8B Int64) | flags(1B, bit0=keyframe) | paramCount(1B)
///  | [paramLen(4B UInt32) + param bytes]... | nalLen(4B UInt32) + nalData bytes`
struct VideoFramePacket: Equatable {
    /// 呈现时间戳,微秒。
    let pts: Int64
    /// 是否关键帧(关键帧才携带 VPS/SPS/PPS 参数集)。
    let isKeyframe: Bool
    /// 参数集(VPS/SPS/PPS),仅关键帧非空。
    let parameterSets: [Data]
    /// AVCC 长度前缀的 NAL 数据。
    let nalData: Data

    static let magic: [UInt8] = [0x5A, 0x4B, 0x56, 0x31] // "ZKV1"

    // MARK: - Encode

    func encode() -> Data {
        var out = Data()
        out.append(contentsOf: VideoFramePacket.magic)
        out.appendLittleEndian(UInt64(bitPattern: pts))
        out.append(isKeyframe ? 0x01 : 0x00)
        out.append(UInt8(parameterSets.count)) // paramCount(1B) → 最多 255 个,足够
        for set in parameterSets {
            out.appendLittleEndian(UInt32(set.count))
            out.append(set)
        }
        out.appendLittleEndian(UInt32(nalData.count))
        out.append(nalData)
        return out
    }

    // MARK: - Decode

    /// 任何越界 / magic 不符 / 长度对不上,一律返回 nil(绝不崩溃、绝不越界读)。
    static func decode(_ data: Data) -> VideoFramePacket? {
        var reader = ByteReader(data)

        guard let magicBytes = reader.readBytes(4), Array(magicBytes) == magic else { return nil }
        guard let ptsRaw = reader.readUInt64LE() else { return nil }
        guard let flags = reader.readUInt8() else { return nil }
        guard let paramCount = reader.readUInt8() else { return nil }

        var sets: [Data] = []
        sets.reserveCapacity(Int(paramCount))
        for _ in 0..<Int(paramCount) {
            guard let len = reader.readUInt32LE(),
                  let bytes = reader.readBytes(Int(len)) else { return nil }
            sets.append(bytes)
        }

        guard let nalLen = reader.readUInt32LE(),
              let nal = reader.readBytes(Int(nalLen)) else { return nil }

        // 必须恰好消耗完所有字节(剩余字节 == nalLen 之后无残留)。
        guard reader.isAtEnd else { return nil }

        return VideoFramePacket(
            pts: Int64(bitPattern: ptsRaw),
            isKeyframe: (flags & 0x01) != 0,
            parameterSets: sets,
            nalData: nal)
    }
}

// MARK: - 小端写入辅助

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLittleEndian(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

// MARK: - 边界安全的字节读取器

/// 顺序游标读取器。所有读取在越界时返回 nil,从不触发越界访问。
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    private var remaining: Int { data.endIndex - offset }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, count <= remaining else { return nil }
        let start = offset
        let end = offset + count
        offset = end
        // 复制出独立子数据,索引归零,避免外部依赖原始切片索引基。
        return Data(data[start..<end])
    }

    mutating func readUInt8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func readUInt32LE() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt32.self).littleEndian
        }
    }

    mutating func readUInt64LE() -> UInt64? {
        guard let bytes = readBytes(8) else { return nil }
        return bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt64.self).littleEndian
        }
    }
}
