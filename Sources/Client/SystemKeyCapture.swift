import AppKit
import CoreGraphics
import ApplicationServices

/// 系统级键盘捕获 —— 用 `CGEventTap` 在会话事件流头部截获 keyDown/keyUp/flagsChanged,
/// 把被系统抢先消费的快捷键(Cmd+Tab、Cmd+Space 等)也拿到手。
///
/// ## 为何不能只靠 NSEvent
/// `RemoteControlView` 的 NSEvent 重写只能收到「派发到本进程」的键盘事件;像 Cmd+Tab
/// 这类被 WindowServer/Dock 抢先处理的全局快捷键根本不会进本进程的响应链。
/// CGEventTap 装在 `.cgSessionEventTap`、`.headInsertEventTap`(会话流最前),
/// 能在系统响应**之前**看到事件,并通过「回调返回 nil」消费掉它,使本机不响应。
///
/// ## 与 Host 的一致性(关键)
/// 转发的 `modifiers` 取 `event.flags.rawValue`,即 **CGEventFlags** 原始位。
/// Host 的 `EventInjector` 注入 `.key` 时直接 `e.flags = CGEventFlags(rawValue: modifiers)`,
/// 两端同构,修饰键在被控机被正确还原。这与 NSEvent 路径(NSEvent.ModifierFlags 位定义不同)
/// 不一样 —— 所以系统捕获走 CGEventFlags 才是端到端正确的修饰位。
///
/// ## 焦点感知
/// 是否消费由外部注入的 `shouldCapture` 决定(由 AppDelegate 接到「窗口为 key 且 app active」)。
/// `shouldCapture()` 为真:转 `InputEvent.key` 抛给 `onKey` 并 `return nil`(吃掉本机事件);
/// 为假:原样放行,MacBook 本机照常工作。
///
/// ## 生命周期 / 内存
/// `tapCreate` 的 `userInfo` 存的是 `Unmanaged.passUnretained(self)`(裸指针,不增引用计数),
/// 回调里 `takeUnretainedValue()` 取回。因此 **本实例必须比 tap 活得久**:
/// AppDelegate 须以强引用持有(`private let keyCapture = SystemKeyCapture()`),
/// 否则回调会野指针。tap/runLoopSource 由本实例持有,`stop()` 时拆除。
final class SystemKeyCapture {
    /// 截获到一条键盘事件且处于「消费」态时回调(已是 CGEventFlags 修饰位)。
    var onKey: ((InputEvent) -> Void)?
    /// 是否消费本机事件(转发给 Host);为假则放行本机。默认不消费。
    var shouldCapture: () -> Bool = { false }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 检查/申请辅助功能(Accessibility)权限 —— CGEventTap 截获键盘的硬性前提。
    /// 带 prompt:未授权时弹系统授权面板,引导去「系统设置 > 隐私与安全性 > 辅助功能」勾选。
    @discardableResult
    func ensureAccessibility() -> Bool {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

    /// 创建并启用 tap,挂到当前 run loop。必须在**主线程**调用(AppDelegate 启动即主线程)。
    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SystemKeyCapture>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[直控] CGEventTap 创建失败(需辅助功能权限)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
        NSLog("[直控] 系统键盘捕获已启动")
    }

    /// tap 回调主体。先处理 tap 被禁(超时/被用户输入打断)→ 重新 enable;
    /// 再按 `shouldCapture` 决定消费(return nil)还是放行(原样返回)。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard shouldCapture() else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.rawValue
        let down: Bool
        if type == .flagsChanged {
            down = SystemKeyCapture.modifierDown(keyCode: keyCode, flags: event.flags)
        } else {
            down = (type == .keyDown)
        }
        onKey?(.key(keyCode: keyCode, down: down, modifiers: modifiers))
        return nil
    }

    /// 修饰键单独按/抬只有 flagsChanged(无 keyDown/Up):靠「该键码对应的 CGEventFlags 位
    /// 此刻是否置位」判断 down/up。键码为虚拟键码(左右修饰键各一个)。
    private static func modifierDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 55, 54: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 57:     return flags.contains(.maskAlphaShift)
        case 63:     return flags.contains(.maskSecondaryFn)
        default:     return false
        }
    }

    /// 拆除 tap 与 run loop source。
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        tap = nil; runLoopSource = nil
    }
}
