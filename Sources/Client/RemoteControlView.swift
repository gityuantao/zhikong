import AppKit
import Carbon.HIToolbox // kVK_* 修饰键虚拟键码

/// 远控视图:在 `PreviewView`(渲染远端画面)基础上捕获本地鼠标/键盘,
/// 归一化坐标后经 `onInput` 抛出 `InputEvent`,由上层经反向通道发给 Host 注入。
///
/// ## 显示模式:填满高度 + 超宽横向平移(`fillHeight = true`)
/// 远端常是超宽/大屏,letterbox 会上下留黑边浪费高度。这里让画面**高度填满窗口**;若因此宽度超出窗口,
/// 内容向两侧溢出(被 `layer.masksToBounds` 裁掉),**鼠标移到左右边缘即自动横向平移**查看溢出部分。
/// 内容矩形(画到哪)与点击归一化(点到哪)都走 `ContentLayout` 同一套几何 → 平移后点击不错位。
///
/// ## 坐标归一化(letterbox/平移校正 + y 翻转)
/// 视图为 AppKit 默认左下原点。`ContentLayout.normalize` 把视图点映射到内容区 [0,1]²,
/// ny=0 对应内容**顶**(已做 y 翻转),与 Host 端 `CGDisplayBounds`(左上原点)对齐。越界忽略。
///
/// ## 合成光标(被控端"看不到鼠标"的解法)
/// 被控机被注入移动时系统常不渲染光标 → Client 看不到指针。这里在画面上**自绘一个光标**贴在当前鼠标
/// 位置(零延迟、永远准确,就是输入落点),并隐藏本机系统光标(避免双光标)。捕获分辨率侧已关 showsCursor,
/// 故画面里不会再有第二个系统光标。
final class RemoteControlView: PreviewView {
    /// 捕获到一条输入事件时回调(已归一化)。
    var onInput: ((InputEvent) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastMousePoint: CGPoint = .zero
    /// 指针当前是否在视图内。仅在内才接管光标(防布局/缩放用陈旧点误隐藏本机光标)。
    private var pointerInside = false

    // 边缘横向平移
    private var panVelocity: CGFloat = 0     // px/sec,符号=方向
    private var panTimer: Timer?
    private static let edgeZone: CGFloat = 64       // 触发平移的边缘带宽(pt)
    private static let maxPanSpeed: CGFloat = 1400  // 贴最边时的平移速度(px/sec)

    // 合成光标
    private var cursorLayer: CALayer?
    private var localCursorHidden = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillHeight = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        fillHeight = true
    }

    // MARK: - 第一响应者 / 追踪区

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 只注册一次,避免 viewDidMoveToWindow 多次进出窗口重复 addObserver(重复触发 unhide 破坏计数平衡)。
    private var observerInstalled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if window == nil {
            // 视图离开窗口:务必恢复本机光标,绝不把用户光标留在隐藏态。
            setLocalCursor(hidden: false)
            stopPanTimer()
        } else if !observerInstalled {
            observerInstalled = true
            // app 失活(切走)时恢复光标与平移。用 app 级通知(单窗口 app:app 失活≈窗口失焦),
            // 只注册一次,杜绝重复注册导致的多次 resetInteractive。
            NotificationCenter.default.addObserver(self, selector: #selector(resetInteractive),
                name: NSApplication.didResignActiveNotification, object: nil)
        }
    }

    @objc private func resetInteractive() {
        pointerInside = false
        setLocalCursor(hidden: false)
        cursorLayer?.isHidden = true
        stopPanTimer()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .mouseMoved 收无按键移动;.mouseEnteredAndExited 管光标隐藏/平移复位;.inVisibleRect 跟随 bounds;
        // .activeAlways 不论 app 是否最前都追踪(远控时本机不一定最前)。
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        // 窗口尺寸变化后内容矩形重算,合成光标重定位到当前鼠标点。
        updateCursor(at: lastMousePoint)
    }

    // MARK: - 内容矩形 / 归一化

    private func contentRect() -> CGRect {
        ContentLayout.rect(videoSize: videoSize, bounds: bounds, fillHeight: fillHeight, panX: panX)
    }

    /// 发送当前点对应的归一化 move(越界则不发)。
    private func emit(at p: CGPoint) {
        guard let (nx, ny) = ContentLayout.normalize(point: p, content: contentRect()) else { return }
        onInput?(.mouseMove(nx: nx, ny: ny))
    }

    // MARK: - 鼠标移动 / 拖拽

    override func mouseMoved(with event: NSEvent) { handleMove(event) }
    override func mouseDragged(with event: NSEvent) { handleMove(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMove(event) }

    private func handleMove(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastMousePoint = p
        pointerInside = true
        emit(at: p)
        updateCursor(at: p)
        updateEdgePan(at: p)
    }

    // MARK: - 鼠标按键

    override func mouseDown(with event: NSEvent) {
        handleMove(event)   // 先把 Host 光标移到落点(button 不带坐标,沿用上次 move)
        onInput?(.mouseButton(button: 0, down: true))
    }
    override func mouseUp(with event: NSEvent) {
        handleMove(event)
        onInput?(.mouseButton(button: 0, down: false))
    }
    override func rightMouseDown(with event: NSEvent) {
        handleMove(event)
        onInput?(.mouseButton(button: 1, down: true))
    }
    override func rightMouseUp(with event: NSEvent) {
        handleMove(event)
        onInput?(.mouseButton(button: 1, down: false))
    }

    override func mouseEntered(with event: NSEvent) { handleMove(event) }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        setLocalCursor(hidden: false)   // 移出视图:恢复本机光标
        cursorLayer?.isHidden = true
        setPanVelocity(0)               // 停止边缘平移
    }

    // MARK: - 滚动

    override func scrollWheel(with event: NSEvent) {
        onInput?(.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY)))
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        onInput?(.key(keyCode: event.keyCode, down: true, modifiers: UInt64(event.modifierFlags.rawValue)))
    }
    override func keyUp(with event: NSEvent) {
        onInput?(.key(keyCode: event.keyCode, down: false, modifiers: UInt64(event.modifierFlags.rawValue)))
    }
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let down = isModifierKeyDown(keyCode: event.keyCode, flags: flags)
        onInput?(.key(keyCode: event.keyCode, down: down, modifiers: UInt64(flags.rawValue)))
    }

    private func isModifierKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift:       return flags.contains(.shift)
        case kVK_Control, kVK_RightControl:   return flags.contains(.control)
        case kVK_Option, kVK_RightOption:     return flags.contains(.option)
        case kVK_Command, kVK_RightCommand:   return flags.contains(.command)
        case kVK_CapsLock:                    return flags.contains(.capsLock)
        case kVK_Function:                    return flags.contains(.function)
        default:                              return false
        }
    }

    // MARK: - 合成光标

    private func ensureCursorLayer() -> CALayer {
        if let cursorLayer { return cursorLayer }
        let l = CALayer()
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        if let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            l.contents = cg
        }
        l.bounds = CGRect(origin: .zero, size: size)
        // hotSpot 在图像内是左上原点;换算成 layer(左下原点)的单位 anchorPoint,使热点落在 position 上。
        let hot = cursor.hotSpot
        if size.width > 0, size.height > 0 {
            l.anchorPoint = CGPoint(x: hot.x / size.width, y: (size.height - hot.y) / size.height)
        }
        l.contentsScale = window?.backingScaleFactor ?? 2
        l.isHidden = true
        l.zPosition = 100   // 始终压在画面层之上
        layer?.addSublayer(l)
        cursorLayer = l
        return l
    }

    /// 鼠标在内容区内 → 画合成光标贴 p、隐藏本机光标;在内容区外(黑边)→ 藏合成、显本机。
    /// 仅当指针确实在视图内才接管光标(否则窗口缩放/布局会用陈旧的 lastMousePoint 误隐藏本机光标)。
    private func updateCursor(at p: CGPoint) {
        let l = ensureCursorLayer()
        guard pointerInside else {
            l.isHidden = true
            setLocalCursor(hidden: false)
            return
        }
        let inContent = ContentLayout.normalize(point: p, content: contentRect()) != nil
        if inContent {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.position = p
            l.isHidden = false
            CATransaction.commit()
            setLocalCursor(hidden: true)
        } else {
            l.isHidden = true
            setLocalCursor(hidden: false)
        }
    }

    /// 计数平衡地隐藏/显示本机系统光标(NSCursor.hide/unhide 是计数式,必须配对)。
    private func setLocalCursor(hidden: Bool) {
        guard hidden != localCursorHidden else { return }
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
        localCursorHidden = hidden
    }

    // MARK: - 边缘横向平移(仅 fillHeight 且内容超宽时)

    private func updateEdgePan(at p: CGPoint) {
        let maxPan = ContentLayout.maxPanX(videoSize: videoSize, bounds: bounds, fillHeight: fillHeight)
        guard maxPan > 0 else { setPanVelocity(0); return }
        let zone = RemoteControlView.edgeZone
        let maxSpeed = RemoteControlView.maxPanSpeed
        var v: CGFloat = 0
        if p.x < bounds.minX + zone {
            let depth = min(1, (bounds.minX + zone - p.x) / zone)   // 越靠边越快
            v = -maxSpeed * depth                                   // 向左:看更靠左的内容(减小 panX)
        } else if p.x > bounds.maxX - zone {
            let depth = min(1, (p.x - (bounds.maxX - zone)) / zone)
            v = maxSpeed * depth                                    // 向右:看更靠右(增大 panX)
        }
        setPanVelocity(v)
    }

    private func setPanVelocity(_ v: CGFloat) {
        panVelocity = v
        if v != 0 { startPanTimer() } else { stopPanTimer() }
    }

    private func startPanTimer() {
        guard panTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(panTick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)   // .common:拖拽/滚动期间也继续触发
        panTimer = t
    }

    private func stopPanTimer() {
        panTimer?.invalidate()
        panTimer = nil
    }

    @objc private func panTick() {
        guard panVelocity != 0 else { stopPanTimer(); return }
        let maxPan = ContentLayout.maxPanX(videoSize: videoSize, bounds: bounds, fillHeight: fillHeight)
        let dt: CGFloat = 1.0 / 60.0
        let newPan = min(max(0, panX + panVelocity * dt), maxPan)
        if newPan == panX { stopPanTimer(); return }   // 已到边界,空转无意义(移动鼠标会重启)
        panX = newPan                                  // didSet → applyContentLayout 重新布局画面
        // 内容平移后,固定屏幕点对应的远端坐标变了 → 补发 move 让 Studio 光标跟随;合成光标仍在原屏幕点。
        emit(at: lastMousePoint)
        updateCursor(at: lastMousePoint)
    }

    deinit {
        if localCursorHidden { NSCursor.unhide() }
        panTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
