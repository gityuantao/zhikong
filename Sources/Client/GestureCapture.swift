import AppKit
import CoreGraphics
import ApplicationServices

/// 触控板「切桌面」手势捕获 —— 用 `CGEventTap` 截获私有的 dock-swipe 手势事件,
/// 把三/四指水平滑动变成一个离散的 `InputEvent.switchSpace(left:)` 转发给被控机,
/// 同时**在本机消费掉**(`return nil`)使本机 Space 不切。
///
/// 结构对齐 `SystemKeyCapture`:tap 装在 `.cgSessionEventTap`,refcon 走
/// `Unmanaged.passUnretained(self)`,焦点感知由外部 `shouldCapture` 注入,
/// `.tapDisabledBy*` 立即重新 enable。**本实例必须比 tap 活得久**(AppDelegate 强引用)。
///
/// ## 字段语义(已由真机探针 GestureProbe v2 实测确定)
/// dock-swipe 是 `type=30`(kCGSEventDockControl),`hidType(110)==23`(kIOHIDEventTypeDockSwipe)。
/// - `axis(123)`:实测**水平切桌面 == 1**(2/3 是垂直/其它,放行给本机 Mission Control)。
/// - `phase(132)`:1=began 2=changed 4=ended 8=cancelled(**4 和 8 都可能是结束**)。
/// - `progress(124)`:**浮点**,沿手势主轴从 0 渐变到 ±1。**符号即方向**。
///   🔴 关键:必须用 `getDoubleValueField` 读。用 `getIntegerValueField` 会把 |x|<1 截断成 0
///   —— 这正是旧实现「滑动毫无反应」的根因(方向恒为 0,emit 被 `value != 0` 跳过)。
///
/// ## 触发策略
/// 不再等 ended(4):一旦本次手势 `|progress|` 越过阈值就**立刻发一个** switchSpace(低延迟、
/// 跟手,且天然规避 4-vs-8 的结束相歧义),发完本次手势内不再重复(`firedThisGesture`)。
/// 聚焦时消费所有水平 dock-swipe(及伴随的 type=29),本机不切。
final class GestureCapture {
    /// 一次水平切桌面手势触发,`left` = 是否向左切。回调里只做非阻塞的 `conn.send`。
    var onSwitchSpace: ((Bool) -> Void)?
    /// 一次**垂直**手势触发,`up` = 是否上划(上划→调度中心,下划→应用窗口)。回调里只做非阻塞的 `conn.send`。
    var onVerticalGesture: ((Bool) -> Void)?
    /// 是否消费本机手势并转发(远程窗口聚焦时)。为假则放行,本机切桌面/Mission Control 照常。
    var shouldCapture: () -> Bool = { false }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - 手势进行中的状态(单线程:tap 回调在主 run loop 上跑)

    /// 本次手势是否已经发过一次 switchSpace(防止一次滑动重复发)。
    private var firedThisGesture = false
    /// 上次真正发出切换的时间(systemUptime,单调),用于冷却去重——
    /// 吸收"一次物理滑动被系统拆成两段手势"导致的多切一屏。
    private var lastFireTime: TimeInterval = 0

    // MARK: - 私有常量(均由 GestureProbe v2 真机实测)

    // 🔴 绝不订阅 type=29(kCGSEventGesture):触控板一动就 ~120/秒 狂发,.defaultTap 下每条都得同步往返
    // 主 run loop,会堵死同线程的 conn.send(发给 Studio 的鼠标指令)和视频 enqueue → 用触控板远控就卡。
    // (4-agent 交叉验证根因。)切桌面只需 type=30,本机抑制也只靠消费 type=30,type=29 无用。
    private static let typeDockControl: UInt32 = 30     // kCGSEventDockControl(切桌面主事件)

    private enum Field {
        static let hidType: UInt32 = 110   // == 23 (kIOHIDEventTypeDockSwipe)
        static let axis: UInt32 = 123      // == 1 水平切桌面
        static let progress: UInt32 = 124  // 浮点主轴进度 0→±1(必须 getDoubleValueField)
        static let phase: UInt32 = 132     // 1=began 2=changed 4=ended 8=cancelled
    }
    private static let kIOHIDEventTypeDockSwipe: Int64 = 23
    private static let axisHorizontal: Int64 = 1
    private static let axisVertical: Int64 = 2   // 上下划(调度中心/应用窗口)
    /// 水平(切桌面)触发阈值:|progress| 越过即发。
    private static let triggerThreshold = 0.2
    /// 垂直(调度中心/应用窗口)触发阈值——明显更低,更灵敏(用户反馈上下要滑很多甚至滑到底才触发)。
    private static let verticalThreshold = 0.06
    /// 触发冷却:两次离散切换至少间隔这么久,防"一次物理滑动被拆成两段手势"导致多切。
    private static let fireCooldown: TimeInterval = 0.35

    /// 检查/申请辅助功能(Accessibility)—— CGEventTap 截获手势的硬性前提(与键盘共用授权)。
    @discardableResult
    func ensureAccessibility() -> Bool {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }

    func start() {
        let mask = CGEventMask(1 << GestureCapture.typeDockControl)   // 只听 type=30,见常量处说明
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GestureCapture>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[直控] 手势 CGEventTap 创建失败(需辅助功能权限)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
        NSLog("[直控] 触控板手势捕获已启动")
    }

    // MARK: - 字段读取

    private func intField(_ e: CGEvent, _ raw: UInt32) -> Int64 {
        e.getIntegerValueField(unsafeBitCast(raw, to: CGEventField.self))
    }
    /// 读浮点字段(progress)。私有字段号经 `unsafeBitCast` 转 CGEventField。
    private func dblField(_ e: CGEvent, _ raw: UInt32) -> Double {
        e.getDoubleValueField(unsafeBitCast(raw, to: CGEventField.self))
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let rawType = type.rawValue
        if rawType == CGEventType.tapDisabledByTimeout.rawValue
            || rawType == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let pass = Unmanaged.passUnretained(event)

        // 只处理 dockControl(30);其它放行(已不订阅 type=29)。
        guard rawType == GestureCapture.typeDockControl else { return pass }

        // 非 dock-swipe(hidType 110 != 23):放行。
        guard intField(event, Field.hidType) == GestureCapture.kIOHIDEventTypeDockSwipe else {
            return pass
        }
        // 仅处理水平(axis=1,切桌面)与垂直(axis=2,调度中心/应用窗口);其它轴放行。
        let axis = intField(event, Field.axis)
        let isHorizontal = axis == GestureCapture.axisHorizontal
        let isVertical = axis == GestureCapture.axisVertical
        guard isHorizontal || isVertical else { return pass }

        // 失焦:不消费、不发,放行本机手势照常;若有残留 in-flight 则复位。
        guard shouldCapture() else {
            resetSwipe()
            return pass
        }

        // —— dock-swipe 且远程聚焦:进入消费 + 阈值触发 ——
        let phase = intField(event, Field.phase)
        switch phase {
        case 1:               // began:新手势开始 → 复位"已发"标记
            firedThisGesture = false
        case 4, 8:            // ended/cancelled:复位并**直接消费返回**。
            // 🔴 绝不在结束事件上再跑下面的触发判定——结束时 progress≈±1 必越阈值,会二次发
            //    → 一次滑动多切一屏(用户报的"滑一下切两屏"真凶)。
            resetSwipe()
            return nil
        default:             // changed(2)等:无需额外状态
            break
        }

        // 阈值触发(每次手势只发一次)。progress 必须按 double 读,符号即方向。垂直阈值更低=更灵敏。
        if !firedThisGesture {
            let progress = dblField(event, Field.progress)
            let threshold = isHorizontal ? GestureCapture.triggerThreshold : GestureCapture.verticalThreshold
            if abs(progress) >= threshold {
                firedThisGesture = true   // 本手势已处理(无论冷却是否放行,都不再重复检查)
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastFireTime >= GestureCapture.fireCooldown {
                    lastFireTime = now
                    if isHorizontal {
                        // 🔴 方向约定:progress<0 → left:true。真机若切反,取反此判断。
                        onSwitchSpace?(progress < 0)
                    } else {
                        // 🔴 方向约定:progress<0 → up:true(上划→调度中心)。真机若反,取反此判断。
                        onVerticalGesture?(progress < 0)
                    }
                }
            }
        }

        // 消费这条 dock-swipe(本机不切桌面/不开调度中心)。
        return nil
    }

    private func resetSwipe() {
        firedThisGesture = false
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        tap = nil; runLoopSource = nil
        resetSwipe()
    }
}
