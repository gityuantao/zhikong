import Foundation

/// 链路反馈消息(Client→Host)——Client 上报近 1 秒**收到的视频帧率**,供 Host 自适应码率。
/// 走反向通道(与输入/剪贴板复用),magic `ZKFB`。线格式:`magic(4B) | fps(2B LE UInt16)`。
///
/// 为何上报 fps:中转对慢下行**丢视频帧**(不回压 Host),故 Host 自身看不到下行拥塞;
/// 但下行拥塞会让 Client 收到的帧率掉下来。Host 比较"自己发的 fps"与"Client 收的 fps",
/// 比值 <1 即丢帧/拥塞 → 降码率(帧更小→中转少丢→Client 帧率回升)。同时也间接反映上行拥塞。
enum FeedbackMessage {
    static let magic: [UInt8] = [0x5A, 0x4B, 0x46, 0x42] // "ZKFB"

    static func encode(fps: Double) -> Data {
        var d = Data(magic)
        let v = UInt16(max(0, min(65535, fps.rounded())))
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        return d
    }

    static func decode(_ data: Data) -> Double? {
        guard data.count == 6, Array(data.prefix(4)) == magic else { return nil }
        let lo = UInt16(data[data.startIndex + 4])
        let hi = UInt16(data[data.startIndex + 5])
        return Double(lo | (hi << 8))
    }
}
