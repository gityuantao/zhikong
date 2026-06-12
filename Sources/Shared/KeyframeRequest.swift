import Foundation

/// 关键帧请求(Client→Host,反向通道,magic `ZKKR`)——线格式:**仅 4 字节 magic**,无载荷。
///
/// 用途:Client 在「解不出画面」时(中途加入还没等到关键帧 / 丢包后解码失序)主动向 Host
/// 要一个关键帧,Host 在下一帧编码时强制 IDR——画面恢复从"等关键帧间隔(~1s)"变"下一帧"。
/// 请求端做了限频(见 `ClientConnection.requestKeyframe`),Host 侧即便收到风暴也只是
/// 把"下一帧强制关键帧"的标记置位,天然幂等、无放大效应。
///
/// 与反向通道其它消息不冲突:InputEvent 首字节是 tag(1..6)≠'Z';ZKC1/ZKFB 靠前 4 字节区分。
enum KeyframeRequest {
    static let magic: [UInt8] = [0x5A, 0x4B, 0x4B, 0x52] // "ZKKR"

    static func encode() -> Data { Data(magic) }

    /// 仅当恰好 4 字节且 magic 匹配才算请求(防止把别的消息前缀误判进来)。
    static func isRequest(_ data: Data) -> Bool {
        data.count == 4 && Array(data) == magic
    }
}
