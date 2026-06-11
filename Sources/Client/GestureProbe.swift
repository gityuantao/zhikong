import AppKit
import CoreGraphics

/// 触控板手势**诊断探针 v2**(非生产代码,只在 `ZHIKONG_GESTURE_PROBE=1` 时启用)。
///
/// v1 已证实:dock-swipe(type=30)事件 session/HID 两层都能 tap 到,phase 走 1→2→8,
/// 而 progress(124)/velocityX(129) 用 `getIntegerValueField` 读全是 0。
/// 强假设:这些是 **−1…1 的浮点字段**,被 int 读取截断成 0 → 方向丢失。
///
/// v2 目标:**定位真正承载「左/右方向」的字段**。只挂 session tap、只看 type=30、
/// 把 113…150 一圈字段用 `getDoubleValueField` 读出来、**只打非零的**,并把 124/129
/// 同时用 int 和 double 读出来对照(验证截断)。做一次缓慢的左滑、右滑,
/// 看哪个字段的符号随方向翻转 —— 那就是方向字段。
enum GestureProbe {
    private static var port: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var logged = 0
    private static let maxLog = 400        // 防跑飞:打满即停

    private static let typeDockControl: UInt32 = 30
    // 已单独打印,不参与「非零字段」扫描。
    private static let known: Set<UInt32> = [123, 132]

    static func start() {
        emit("============= 直控 手势诊断探针 v2(定位方向字段)=============")
        emit("只看 dockControl(type=30),字段按【双精度】读,只打非零的。")
        emit("请缓慢、完整地做:① 三指左滑 →停1秒→ ② 三指右滑 →停1秒→ ③ 四指左滑 →停→ ④ 四指右滑")
        emit("找:哪个 f<num> 的符号在「左」和「右」之间翻转 —— 那就是方向。")
        emit("=============================================================")

        let mask = CGEventMask(1) << typeDockControl   // 只要 type=30
        let cb: CGEventTapCallBack = { _, type, event, _ in
            GestureProbe.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)     // 纯观察,放行
        }
        guard let p = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: cb, userInfo: nil) else {
            emit("❌ tap 创建失败(辅助功能未授权?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        port = p; source = src
        emit("✅ tap 已启用(session 级,只听 type=30)。开始滑动……")
    }

    private static func handle(type: CGEventType, event: CGEvent) {
        let raw = type.rawValue
        if raw == CGEventType.tapDisabledByTimeout.rawValue
            || raw == CGEventType.tapDisabledByUserInput.rawValue {
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            return
        }
        guard raw == typeDockControl, logged < maxLog else { return }

        let phase = intField(event, 132)
        let axis = intField(event, 123)

        // 124 / 129 同时 int+double 读,验证「截断」假设。
        let i124 = intField(event, 124), d124 = dblField(event, 124)
        let i129 = intField(event, 129), d129 = dblField(event, 129)

        // 113…150 扫描,挑出非零(double)字段。
        var nonZero: [String] = []
        for f: UInt32 in 113...150 where !known.contains(f) {
            let d = dblField(event, f)
            if d != 0 && d.isFinite {
                nonZero.append("f\(f)=\(fmt(d))")
            }
        }
        let nz = nonZero.isEmpty ? "(无非零字段)" : nonZero.joined(separator: " ")
        emit("phase=\(phase) axis=\(axis) | 124[i=\(i124) d=\(fmt(d124))] 129[i=\(i129) d=\(fmt(d129))] | \(nz)")
        logged += 1
        if logged == maxLog { emit("（已达上限，停止打印；可 Ctrl+C 结束）") }
    }

    private static func intField(_ e: CGEvent, _ n: UInt32) -> Int64 {
        e.getIntegerValueField(unsafeBitCast(n, to: CGEventField.self))
    }
    private static func dblField(_ e: CGEvent, _ n: UInt32) -> Double {
        e.getDoubleValueField(unsafeBitCast(n, to: CGEventField.self))
    }
    private static func fmt(_ d: Double) -> String {
        d.isFinite ? String(format: "%.3f", d) : "nan"
    }
    private static func emit(_ s: String) { print(s); NSLog("%@", s) }
}
