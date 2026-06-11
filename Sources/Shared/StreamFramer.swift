import Foundation

/// 长度前缀分帧器 —— 把字节流切回离散消息。
///
/// 线格式:`length(4B 大端 UInt32) | payload bytes`。
/// 发送端用 `frame(_:)` 给每条消息加前缀;接收端把每次收到的字节块丢进
/// `append(_:)`,累积内部缓冲并循环切出所有完整帧(可能 0 条、可能多条)。
/// 半包(不足一帧)留在缓冲里等后续字节补齐。空载荷(length==0)是合法帧。
///
/// **长度上限(防内存耗尽)**:长度前缀在加密信道**外**、是明文——恶意/故障的对端或中转
/// 可宣告一个 4GB 的帧长,让接收端无限囤积字节。超过 `maxFrameLength`(与 zkrelay.py 的
/// MAX_FRAME 一致)即置 `poisoned` 并清空缓冲;流已不可信(无法重新对齐帧边界),
/// 调用方应断开连接重连(重连会换新 framer)。
struct StreamFramer {
    /// 单帧载荷长度上限。正常帧远小于此:关键帧约几 MB(20Mbps@60fps),音频/输入更小。
    static let maxFrameLength = 16 * 1024 * 1024
    /// 流已损坏(见上)。一旦置位,后续 `append` 全部丢弃;调用方应断开连接。
    private(set) var poisoned = false
    /// 累积缓冲:已收到但尚未切出完整帧的字节。
    private var buffer = Data()

    /// 给一条消息加 4 字节大端长度前缀。
    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// 喂入一块字节,返回本次能切出的所有完整帧载荷(按到达顺序)。
    mutating func append(_ chunk: Data) -> [Data] {
        guard !poisoned else { return [] }
        // chunk 可能是带非零 startIndex 的切片(如 .prefix/.suffix);append(Data)
        // 会按字节复制,内部 buffer 始终从 0 索引基,无需担心切片索引基。
        buffer.append(chunk)

        var messages: [Data] = []
        while true {
            // 头部 4 字节才能读出长度。
            guard buffer.count >= 4 else { break }
            let length = readBigEndianUInt32(at: buffer.startIndex)
            // 帧长超上限:流不可信且无法重对齐 → 标记损坏、清缓冲,已切出的完整帧仍然返回。
            guard Int(length) <= StreamFramer.maxFrameLength else {
                poisoned = true
                buffer = Data()
                return messages
            }
            let frameTotal = 4 + Int(length)
            // 整帧(头+载荷)还没到齐,留待下次。
            guard buffer.count >= frameTotal else { break }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: frameTotal)
            // 复制出独立载荷,索引归零。
            messages.append(Data(buffer[payloadStart..<payloadEnd]))

            // 丢弃已消费的整帧,剩余字节继续循环(可能含下一帧)。
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
        return messages
    }

    /// 从 buffer 指定偏移读 4 字节大端 UInt32(已保证 ≥4 字节可读)。
    private func readBigEndianUInt32(at start: Data.Index) -> UInt32 {
        let b0 = UInt32(buffer[start])
        let b1 = UInt32(buffer[buffer.index(start, offsetBy: 1)])
        let b2 = UInt32(buffer[buffer.index(start, offsetBy: 2)])
        let b3 = UInt32(buffer[buffer.index(start, offsetBy: 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
