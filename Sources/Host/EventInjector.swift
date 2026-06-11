import CoreGraphics
import AppKit

/// `InputEvent → CGEventPost` 注入到 Studio(被控机)。
///
/// 坐标系约定:Client 端把点击点归一化到 0..1(相对视频内容区,letterbox 校正后),
/// 其中 ny=0 表示视频内容区**顶部**、ny=1 表示**底部**(详见 RemoteControlView)。
/// 这里把归一化坐标映射回主显示器的全局矩形 `CGDisplayBounds(CGMainDisplayID())`。
///
/// 关键:`CGDisplayBounds` 用 **top-left 原点、y 向下** 的全局坐标(与 NSScreen 的
/// bottom-up 不同)。因此 ny=0(视频顶部)→ bounds.minY(屏幕顶部),
/// 直接 `minY + ny*height` 即可,无需在此翻转——翻转已在 Client 捕获端完成。
/// CGEvent 注入也吃这套 top-left 全局坐标,所以"Client 视频顶部点击 → Studio 屏幕顶部"成立。
final class EventInjector {
    /// 最近一次鼠标位置(全局像素)。button/scroll/拖拽都复用它,
    /// 因为这些事件本身不带坐标,需沿用上一次 mouseMove 落点。
    private var lastPoint = CGPoint.zero
    /// 左键是否处于按下态——决定 mouseMove 应发 `.mouseMoved` 还是 `.leftMouseDragged`。
    private var leftDown = false

    func inject(_ event: InputEvent) {
        let b = CGDisplayBounds(CGMainDisplayID())
        switch event {
        case .mouseMove(let nx, let ny):
            lastPoint = CGPoint(x: b.minX + CGFloat(nx) * b.width,
                                y: b.minY + CGFloat(ny) * b.height)
            let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: lastPoint, mouseButton: .left))

        case .mouseButton(let button, let down):
            let left = button == 0
            if left { leftDown = down }
            let type: CGEventType = left ? (down ? .leftMouseDown : .leftMouseUp)
                                         : (down ? .rightMouseDown : .rightMouseUp)
            post(CGEvent(mouseEventSource: nil, mouseType: type,
                         mouseCursorPosition: lastPoint,
                         mouseButton: left ? .left : .right))

        case .scroll(let dx, let dy):
            // wheel1=垂直(dy),wheel2=水平(dx);像素单位。Int32 截断对滚动量足够。
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0))

        case .key(let keyCode, let down, let modifiers):
            let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            e?.flags = CGEventFlags(rawValue: modifiers)
            post(e)

        case .switchSpace(let left):
            switchSpace(left: left)

        case .missionControl(let up):
            missionControl(up: up)
        }
    }

    /// 切被控机的 Spaces。
    ///
    /// ## 为何用 AppleScript 而非 CGEvent 方向键
    /// 现代 macOS(尤其 Sonoma/Tahoe)会**静默吞掉**合成注入的方向键/功能键系统热键 ——
    /// 直接 `CGEvent(... virtualKey: 123/124 ...)` + Ctrl 在被控机不会触发"移到左/右边一个 Space",
    /// 反而可能把 `[;5D` 之类的转义序列漏给前台 App。改走 `System Events`(受信任进程),
    /// 由它代发 `key code N using control down`,系统会认这条热键。
    ///
    /// ## 前提(用户须开)
    /// 被控机「系统设置 › 键盘 › 快捷键 › 调度中心 › 移到左边/右边一个 Space」**必须启用**,
    /// 否则 key code 123/124 + Ctrl 无对应快捷键、切不动。
    /// Host 进程首次跑 osascript 会弹**自动化(Automation)授权**(允许控制 System Events),
    /// 用户点允许后才生效。
    ///
    /// ## 非阻塞
    /// `try? p.run()` 后**不** `waitUntilExit()` —— 注入路径不能被 osascript 启动开销(数十 ms)卡住。
    /// 进程退出由系统回收;构造/启动失败静默丢弃,绝不崩溃。
    private func switchSpace(left: Bool) {
        // 123 = 左方向键(移到左边一个 Space),124 = 右方向键(移到右边一个 Space)。
        let keyCode = left ? 123 : 124
        let script = "tell application \"System Events\" to key code \(keyCode) using control down"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()   // 非阻塞:不 waitUntilExit,避免阻塞注入路径
    }

    /// 切被控机的「调度中心 / 应用窗口」(垂直手势)。
    ///
    /// 与 `switchSpace` 同理:合成的功能键系统热键会被现代 macOS 静默吞掉,故走 `System Events`
    /// 代发 `key code 126/125 using control down`。
    /// - up=true:key code 126(↑)+ Ctrl = 调度中心(Mission Control)。
    /// - up=false:key code 125(↓)+ Ctrl = 应用窗口(App Exposé)。
    ///
    /// ## 前提(用户须开)
    /// 被控机「系统设置 › 键盘 › 键盘快捷键 › 调度中心」里「调度中心」「应用窗口」**须启用**
    /// (与切 Space 的 Ctrl+←/→ 同一面板)。非阻塞,失败静默丢弃。
    private func missionControl(up: Bool) {
        let keyCode = up ? 126 : 125
        let script = "tell application \"System Events\" to key code \(keyCode) using control down"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()   // 非阻塞:不 waitUntilExit
    }

    /// 统一发送口。CGEvent 各构造器可空(资源不足等),失败则静默丢弃,绝不崩溃。
    /// `.cgSessionEventTap` 把事件注入用户会话级事件流,使全局点击/键入生效。
    private func post(_ event: CGEvent?) {
        event?.post(tap: .cgSessionEventTap)
    }

    /// 检查/申请辅助功能(Accessibility)权限——CGEventPost 注入的硬性前提。
    /// 带 prompt 选项:未授权时弹系统授权面板,引导用户去「系统设置 > 隐私与安全性 > 辅助功能」勾选。
    @discardableResult
    func ensureAccessibility() -> Bool {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }
}
