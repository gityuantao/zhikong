import Foundation

/// 剪贴板同步消息(纯文本)——与视频/音频复用同一条连接,按 4 字节 magic `ZKC1` 区分。
/// 双向流动(Host↔Client)。线格式:`magic(4B "ZKC1") | UTF-8 文本字节`。
///
/// 与 InputEvent 不冲突:InputEvent 首字节是 tag(1..6),绝不会等于 'Z'(0x5A),故同一反向通道里可共存。
enum ClipboardMessage {
    static let magic: [UInt8] = [0x5A, 0x4B, 0x43, 0x31] // "ZKC1"

    static func encode(_ text: String) -> Data {
        var d = Data(magic)
        d.append(Data(text.utf8))
        return d
    }

    /// magic 不符返回 nil;其余按 UTF-8 解(非法字节用替换符,不失败)。
    static func decode(_ data: Data) -> String? {
        guard data.count >= 4, Array(data.prefix(4)) == magic else { return nil }
        return String(decoding: data.dropFirst(4), as: UTF8.self)
    }
}
