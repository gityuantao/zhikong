import Foundation

/// 中转控制消息(中转 → 端,**明文**,magic `ZKRL`)——告知对端是否在线(被控端/控制端是否配上了)。
///
/// 线格式:`magic(4B "ZKRL") | present(1B 0/1)`,**整条恰好 5 字节**。
///
/// 与端到端加密共存的关键:加密后的对端帧带 nonce+tag,**至少 28 字节**;ZKRL 恒为 5 字节,
/// 故收端用"长度==5 且前 4 字节为 ZKRL"即可在**开箱前**把中转控制帧拣出来(中转没有口令、发不了密文)。
enum RelayControl {
    static let magic: [UInt8] = [0x5A, 0x4B, 0x52, 0x4C] // "ZKRL"
    static let frameLength = 5

    static func encodePresence(_ present: Bool) -> Data {
        var d = Data(magic)
        d.append(present ? 1 : 0)
        return d
    }

    /// 仅当恰好 5 字节且 magic 匹配才解析(避免误判加密帧)。返回对端是否在线。
    static func decodePresence(_ data: Data) -> Bool? {
        guard data.count == frameLength, Array(data.prefix(4)) == magic else { return nil }
        return data[data.startIndex + 4] != 0
    }
}
