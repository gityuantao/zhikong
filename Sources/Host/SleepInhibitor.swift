import Foundation

/// 防止系统/显示器空闲休眠 —— 远程被控的 Host 必须常醒:
/// 人在外面想连时若 Studio 已进系统睡眠,中转上根本没有 Host 在场,连不上;
/// 且显示器睡眠会让 ScreenCaptureKit 停止出帧(合成器不再绘制)→ 画面冻结。
///
/// 基于 `ProcessInfo.beginActivity`,持有 token 期间生效;`end()` 或 token 释放即恢复正常电源策略。
/// 注意:这只挡**空闲**休眠;用户手动合盖/选「睡眠」仍会睡(符合预期,不强行违抗用户意图)。
final class SleepInhibitor {
    private var token: NSObjectProtocol?

    /// 开始阻止空闲休眠(幂等:已持有则不重复申请)。
    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: reason)
        NSLog("[直控] 已阻止空闲休眠(远控常驻):%@", reason)
    }

    /// 恢复正常电源策略。
    func end() {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
            NSLog("[直控] 已恢复电源策略(解除防休眠)")
        }
        token = nil
    }
}
