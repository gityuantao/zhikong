import Foundation

/// 自适应码率控制器(纯逻辑,可单测)。输入"投递率"(Client 收帧 fps / Host 发帧 fps),
/// 输出新码率。**保护式 AIMD**:丢帧明显→快速乘性降(保跟手);持续通畅→缓慢加性升(到 ceiling 止)。
///
/// 默认 ceiling = 起始码率 = 配置值 ⇒ **只降不升**(纯保护,无向上探测=无振荡)。
/// 想"网好更清晰"就把 ceiling 调高于起始(env ZHIKONG_WAN_BITRATE_MAX),才允许向上探测。
struct AdaptiveBitrateController {
    let floorBps: Int
    let ceilingBps: Int
    private(set) var bitrate: Int
    private var goodStreak = 0

    /// 投递率低于此判为拥塞/丢帧 → 降。
    static let congestedRatio = 0.85
    /// 投递率高于此判为通畅。
    static let healthyRatio = 0.95
    /// 连续多少次通畅才升一档(抗抖动,避免一好就冲)。
    static let raiseStreak = 3
    static let downFactor = 0.75      // 拥塞:降到 75%
    static let upStepBps = 1_000_000  // 通畅:每次升 1Mbps

    init(start: Int, floor: Int, ceiling: Int) {
        self.floorBps = floor
        self.ceilingBps = max(floor, ceiling)
        self.bitrate = min(max(start, floor), self.ceilingBps)
    }

    /// 喂一次投递率,返回(可能更新后的)码率。`deliveryRatio` = clientFps/hostFps,1.0=无丢帧。
    @discardableResult
    mutating func update(deliveryRatio r: Double) -> Int {
        if r < AdaptiveBitrateController.congestedRatio {
            bitrate = max(floorBps, Int(Double(bitrate) * AdaptiveBitrateController.downFactor))
            goodStreak = 0
        } else if r >= AdaptiveBitrateController.healthyRatio {
            goodStreak += 1
            if goodStreak >= AdaptiveBitrateController.raiseStreak {
                bitrate = min(ceilingBps, bitrate + AdaptiveBitrateController.upStepBps)
                goodStreak = 0
            }
        } else {
            goodStreak = 0   // 中间带:保持
        }
        return bitrate
    }
}
